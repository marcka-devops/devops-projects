# ============================================================
# deploy.ps1
# Grafana Observability Stack for EKS
# Components: Prometheus · Loki · Grafana Alloy · Grafana
# Target app namespace: qa
# Run: .\deploy.ps1
# ============================================================

param(
    [switch]$Yes
)

Set-Location -LiteralPath $PSScriptRoot

# ════════════════════════════════════════════════════════════
#  EDIT THESE BEFORE RUNNING
# ════════════════════════════════════════════════════════════
$S3_BUCKET              = "qa-demo-s3-777-86"
$AWS_REGION             = "us-east-1"
$CLUSTER_NAME           = "my-cluster"
$MONITORING_NS          = "monitoring"
$QA_NS                  = "qa"
$GRAFANA_ADMIN_PASSWORD = $env:GRAFANA_ADMIN_PASSWORD  # set before running; never hard-code it here
$NODE_ROLE_NAME         = "<NODE_INSTANCE_ROLE_NAME>"   # eksctl-<cluster>-nodegroup-...-NodeInstanceRole-...
# ════════════════════════════════════════════════════════════

if (-not $GRAFANA_ADMIN_PASSWORD) { Write-Host "[ERROR] Set `$env:GRAFANA_ADMIN_PASSWORD first." -ForegroundColor Red; exit 1 }

# Chart versions
$PROMETHEUS_CHART_VERSION = "67.4.0"
$LOKI_CHART_VERSION       = "6.29.0"
$ALLOY_CHART_VERSION      = "0.12.0"
$GRAFANA_CHART_VERSION    = "8.10.4"

# ── Helpers ──────────────────────────────────────────────────
function Log  { param($msg) Write-Host "[INFO]  $msg" -ForegroundColor Green }
function Warn { param($msg) Write-Host "[WARN]  $msg" -ForegroundColor Yellow }
function Step { param($msg) Write-Host "`n══ $msg" -ForegroundColor Cyan }
function Die  {
    param($msg)
    Write-Host "[ERROR] $msg" -ForegroundColor Red
    exit 1
}

function Test-NativeCommand {
    param([scriptblock]$Command)
    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        & $Command 2>$null | Out-Null
        return ($LASTEXITCODE -eq 0)
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
}

function Assert-NativeExitCode {
    param([string]$Operation)
    if ($LASTEXITCODE -ne 0) {
        Die "$Operation failed with exit code $LASTEXITCODE."
    }
}

$ErrorActionPreference = "Stop"

# ── Pre-flight ────────────────────────────────────────────────
Step "Pre-flight checks"

if (-not (Get-Command helm    -ErrorAction SilentlyContinue)) { Die "helm not found. Install from https://helm.sh/docs/intro/install/" }
if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) { Die "kubectl not found." }
if (-not (Get-Command aws     -ErrorAction SilentlyContinue)) { Die "aws CLI not found." }

$CONTEXT = kubectl config current-context
Assert-NativeExitCode "Kubernetes context lookup"
Log "kubectl context : $CONTEXT"
Log "AWS region      : $AWS_REGION"
Log "Cluster         : $CLUSTER_NAME"
Log "S3 bucket       : $S3_BUCKET"
Log "Node role       : $NODE_ROLE_NAME"

if (-not $Yes) {
    $CONFIRM = Read-Host "`nProceed with deployment? (y/n)"
    if ($CONFIRM -ne "y") { Die "Aborted." }
}

# ── Namespaces ────────────────────────────────────────────────
Step "Creating namespaces"

kubectl create namespace $MONITORING_NS --dry-run=client -o yaml | kubectl apply -f -
Assert-NativeExitCode "Monitoring namespace creation"
kubectl create namespace $QA_NS         --dry-run=client -o yaml | kubectl apply -f -
Assert-NativeExitCode "QA namespace creation"

kubectl label namespace $MONITORING_NS "kubernetes.io/metadata.name=$MONITORING_NS" --overwrite
Assert-NativeExitCode "Monitoring namespace labeling"
kubectl label namespace $QA_NS         "kubernetes.io/metadata.name=$QA_NS"         --overwrite
Assert-NativeExitCode "QA namespace labeling"

Log "Namespaces ready"

# ── Grafana admin secret ──────────────────────────────────────
Step "Creating Grafana admin secret"

kubectl create secret generic grafana-admin-secret `
    --namespace $MONITORING_NS `
    --from-literal=admin-user=admin `
    "--from-literal=admin-password=$GRAFANA_ADMIN_PASSWORD" `
    --dry-run=client -o yaml | kubectl apply -f -
Assert-NativeExitCode "Grafana admin secret creation"

Log "Secret: grafana-admin-secret created"

# ── S3 bucket for Loki ────────────────────────────────────────
Step "Setting up S3 bucket for Loki: $S3_BUCKET"

if (Test-NativeCommand { aws s3 ls "s3://$S3_BUCKET" --region $AWS_REGION }) {
    Log "Bucket already exists, skipping creation"
} else {
    Log "Creating bucket..."

    $createBucketArgs = @(
        "s3api", "create-bucket",
        "--bucket", $S3_BUCKET,
        "--region", $AWS_REGION
    )
    if ($AWS_REGION -ne "us-east-1") {
        $createBucketArgs += @("--create-bucket-configuration", "LocationConstraint=$AWS_REGION")
    }
    aws @createBucketArgs
    Assert-NativeExitCode "S3 bucket creation"

    aws s3api put-public-access-block `
        --bucket $S3_BUCKET `
        --public-access-block-configuration "BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true"
    Assert-NativeExitCode "S3 public access block configuration"

    $lifecycle = @'
{
  "Rules": [{
    "ID": "loki-log-expiry",
    "Status": "Enabled",
    "Filter": {"Prefix": ""},
    "Expiration": {"Days": 35},
    "NoncurrentVersionExpiration": {"NoncurrentDays": 7}
  }]
}
'@
    $lifecycleFile = Join-Path $env:TEMP "loki-bucket-lifecycle-$([guid]::NewGuid().ToString('N')).json"
    try {
        Set-Content -LiteralPath $lifecycleFile -Value $lifecycle -Encoding Ascii
        aws s3api put-bucket-lifecycle-configuration `
            --bucket $S3_BUCKET `
            --lifecycle-configuration "file://$lifecycleFile"
        Assert-NativeExitCode "S3 lifecycle configuration"
    } finally {
        Remove-Item -LiteralPath $lifecycleFile -Force -ErrorAction SilentlyContinue
    }

    Log "Bucket created with lifecycle policy (35-day expiry)"
}

# ── IAM policy for Loki S3 access ─────────────────────────────
Step "Setting up IAM policy for Loki S3 access"

# Patch the bucket name into the policy file
(Get-Content "05-loki-s3-iam-policy.json") -replace '<YOUR_S3_BUCKET>|qa-demo-s3-777-[^"/]+', $S3_BUCKET |
    Set-Content "05-loki-s3-iam-policy.json"

# Check if LokiS3Policy already exists
$ACCOUNT_ID = aws sts get-caller-identity --query Account --output text
Assert-NativeExitCode "AWS account lookup"
$POLICY_ARN = "arn:aws:iam::${ACCOUNT_ID}:policy/LokiS3Policy"

if (Test-NativeCommand { aws iam get-policy --policy-arn $POLICY_ARN }) {
    Log "LokiS3Policy exists - creating new version with correct bucket name..."
    aws iam create-policy-version `
        --policy-arn $POLICY_ARN `
        --policy-document file://05-loki-s3-iam-policy.json `
        --set-as-default
    Assert-NativeExitCode "Loki IAM policy update"
    Log "LokiS3Policy updated"
} else {
    Log "Creating LokiS3Policy..."
    $POLICY_ARN = (aws iam create-policy `
        --policy-name LokiS3Policy `
        --policy-document file://05-loki-s3-iam-policy.json `
        --query Policy.Arn --output text)
    Assert-NativeExitCode "Loki IAM policy creation"
    Log "LokiS3Policy created: $POLICY_ARN"
}

# Attach to node role
Log "Attaching LokiS3Policy to node role: $NODE_ROLE_NAME"
aws iam attach-role-policy `
    --role-name $NODE_ROLE_NAME `
    --policy-arn $POLICY_ARN
Assert-NativeExitCode "Loki IAM policy attachment"

Log "IAM policy attached"

# Patch S3 bucket name and region into loki values
Log "Patching S3 config into 02-loki-values.yaml..."
(Get-Content "02-loki-values.yaml") `
    -replace 'YOUR_S3_BUCKET|qa-demo-s3-777-[A-Za-z0-9-]+', $S3_BUCKET `
    -replace 'ap-south-1', $AWS_REGION |
    Set-Content "02-loki-values.yaml"
Log "Loki values patched"

# ── Helm repos ────────────────────────────────────────────────
Step "Adding & updating Helm repos"

helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
Assert-NativeExitCode "Prometheus Helm repository setup"
helm repo add grafana               https://grafana.github.io/helm-charts
Assert-NativeExitCode "Grafana Helm repository setup"
helm repo add eks                   https://aws.github.io/eks-charts
Assert-NativeExitCode "EKS Helm repository setup"
helm repo update
Assert-NativeExitCode "Helm repository update"

Log "Repos updated"

# ── AWS Load Balancer Controller ──────────────────────────────
Step "Checking AWS Load Balancer Controller"

if (Test-NativeCommand { helm status aws-load-balancer-controller -n kube-system }) {
    Log "AWS Load Balancer Controller already installed, skipping"
} else {
    Warn "AWS Load Balancer Controller not found - installing..."
    Warn "Make sure your node IAM role has AWSLoadBalancerControllerIAMPolicy attached."

    helm install aws-load-balancer-controller eks/aws-load-balancer-controller `
        --namespace kube-system `
        --set "clusterName=$CLUSTER_NAME" `
        --set serviceAccount.create=true `
        --set serviceAccount.name=aws-load-balancer-controller `
        --wait `
        --timeout 5m
    Assert-NativeExitCode "AWS Load Balancer Controller installation"

    Log "AWS Load Balancer Controller installed"
}

# ── 1. Prometheus ─────────────────────────────────────────────
Step "1/4 Installing kube-prometheus-stack"

helm upgrade --install monitoring prometheus-community/kube-prometheus-stack `
    --namespace $MONITORING_NS `
    --values 01-prometheus-values.yaml `
    --version $PROMETHEUS_CHART_VERSION `
    --wait `
    --timeout 10m
Assert-NativeExitCode "Prometheus installation"

Log "Prometheus stack installed"

# ── 2. Loki ───────────────────────────────────────────────────
Step "2/4 Installing Loki"

helm upgrade --install loki grafana/loki `
    --namespace $MONITORING_NS `
    --values 02-loki-values.yaml `
    --version $LOKI_CHART_VERSION `
    --wait `
    --timeout 10m
Assert-NativeExitCode "Loki installation"

Log "Loki installed"

# ── 3. Grafana Alloy ──────────────────────────────────────────
Step "3/4 Installing Grafana Alloy"

helm upgrade --install alloy grafana/alloy `
    --namespace $MONITORING_NS `
    --values 03-alloy-values.yaml `
    --version $ALLOY_CHART_VERSION `
    --wait `
    --timeout 10m
Assert-NativeExitCode "Grafana Alloy installation"

Log "Grafana Alloy installed"

# ── 4. Grafana ────────────────────────────────────────────────
Step "4/4 Installing Grafana"

helm upgrade --install grafana grafana/grafana `
    --namespace $MONITORING_NS `
    --values 04-grafana-values.yaml `
    --version $GRAFANA_CHART_VERSION `
    --set ingress.enabled=true `
    --set ingress.ingressClassName=alb `
    --set "ingress.path=/" `
    --set "ingress.pathType=Prefix" `
    --wait `
    --timeout 10m
Assert-NativeExitCode "Grafana installation"

Log "Grafana installed"

# ── Verify ────────────────────────────────────────────────────
Step "Pod status in namespace: $MONITORING_NS"
kubectl get pods -n $MONITORING_NS -o wide
Assert-NativeExitCode "Monitoring pod status query"

Step "Ingress status - ALB needs ~2-3 min to provision"
kubectl get ingress -n $MONITORING_NS
Assert-NativeExitCode "Monitoring ingress status query"

# ── Get admin password ────────────────────────────────────────
Step "Grafana admin password"
$encoded = kubectl get secret --namespace $MONITORING_NS grafana-admin-secret -o jsonpath="{.data.admin-password}"
Assert-NativeExitCode "Grafana admin secret verification"
$password = [System.Text.Encoding]::UTF8.GetString([System.Convert]::FromBase64String($encoded))
Log "Password: $password"

# ── Summary ───────────────────────────────────────────────────
Write-Host ""
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  Deployment complete!" -ForegroundColor Green
Write-Host "════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "  Get Grafana ALB URL (wait ~2-3 min after deploy):"
Write-Host "  kubectl get ingress grafana -n $MONITORING_NS"
Write-Host ""
Write-Host "  Grafana login:"
Write-Host "    User     : admin"
Write-Host "    Password : $GRAFANA_ADMIN_PASSWORD"
Write-Host ""
Write-Host "  Verify logs are flowing (run after ~2 min):"
Write-Host "  kubectl logs -n $MONITORING_NS -l app.kubernetes.io/name=alloy --tail=10"
Write-Host ""
Write-Host "  Check Loki labels (confirms log ingestion):"
Write-Host "  kubectl run lokitest --image=busybox:1.28 --rm -it --restart=Never -n $MONITORING_NS -- wget -qO- `"http://loki-gateway/loki/api/v1/labels`""
Write-Host ""
