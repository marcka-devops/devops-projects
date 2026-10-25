#!/usr/bin/env bash
# ============================================================
# provision.sh
# Builds the AWS side of the 3-Tier User Platform from scratch:
#   EKS cluster and node group, EBS CSI driver, AWS Load Balancer Controller,
#   External Secrets with per-environment IAM roles, MySQL credentials in
#   Secrets Manager, GitHub Actions OIDC deploy roles with EKS access, the
#   qa/prod namespaces with MySQL, and (optionally) ACM certificates.
#
# Reconstructed from the commands used to build the original environment.
# Safe to re-run: every step checks whether its resource already exists.
#
# Run from the project root in Git Bash, Linux or macOS:
#   export MYSQL_ROOT_PASSWORD=... MYSQL_PASSWORD=... DOCKERHUB_USERNAME=... DOCKERHUB_TOKEN=...
#   bash scripts/provision.sh
#
# Needs: aws CLI v2, eksctl, kubectl, helm, curl, python3; an AWS identity
# that can create EKS, EC2, IAM, Secrets Manager and ACM resources.
# ============================================================
set -euo pipefail

# ════════════════════════════════════════════════════════════
#  EDIT THESE BEFORE RUNNING
# ════════════════════════════════════════════════════════════
AWS_REGION="us-east-1"
CLUSTER_NAME="my-cluster-1"
NODEGROUP_NAME="my-nodegroup-medium"
NODE_TYPE="m7i-flex.large"     # 2 vCPU / 8 GiB / 29 pods; t3.small (11 pods) is too small for this stack
NODE_COUNT=3
NODE_MIN=2
NODE_MAX=4
GITHUB_OWNER="<GITHUB_OWNER>"   # e.g. your GitHub user or org
GITHUB_REPO="<GITHUB_REPO>"     # repository that runs the workflows
QA_BRANCH="qa"
PROD_BRANCH="main"
MYSQL_DATABASE="test_db"
MYSQL_USER="appuser"
QA_DOMAIN=""                     # e.g. qa.example.com; leave empty to skip ACM
PROD_DOMAIN=""                   # e.g. example.com; leave empty to skip ACM
LBC_CHART_VERSION=""             # aws-load-balancer-controller chart version; empty = latest
# ════════════════════════════════════════════════════════════

ENVIRONMENTS=(qa prod)
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
cd "$(dirname "$0")/.."

say()  { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
die()  { printf '\033[31m[ERROR] %s\033[0m\n' "$*" >&2; exit 1; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

# ── Pre-flight ───────────────────────────────────────────────
say "Pre-flight checks"
for tool in aws eksctl kubectl helm curl; do
  command -v "$tool" >/dev/null || die "$tool not found on PATH."
done
PY=$(command -v python3 || command -v python) || die "Python 3 not found on PATH."
[[ "$GITHUB_OWNER" != "<GITHUB_OWNER>" && "$GITHUB_REPO" != "<GITHUB_REPO>" ]] || die "Set GITHUB_OWNER and GITHUB_REPO at the top of this script."
for v in MYSQL_ROOT_PASSWORD MYSQL_PASSWORD DOCKERHUB_USERNAME DOCKERHUB_TOKEN; do
  [[ -n "${!v:-}" ]] || die "Set \$$v in your environment first (never hard-code it here)."
done
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
info "AWS identity : $(aws sts get-caller-identity --query Arn --output text)"
info "Region       : $AWS_REGION"
info "Cluster      : $CLUSTER_NAME ($NODE_COUNT x $NODE_TYPE)"

# GitHub now puts numeric IDs in the OIDC subject claim:
#   repo:<owner>@<owner_id>/<repo>@<repo_id>:ref:refs/heads/<branch>
# The trust policies must match that exact format, so look the IDs up.
read -r GITHUB_OWNER_ID GITHUB_REPO_ID < <(curl -fsS "https://api.github.com/repos/$GITHUB_OWNER/$GITHUB_REPO" |
  "$PY" -c "import sys,json; d=json.load(sys.stdin); print(d['owner']['id'], d['id'])") ||
  die "Could not look up $GITHUB_OWNER/$GITHUB_REPO on GitHub (private repos need GITHUB_TOKEN; set the IDs by hand)."
info "GitHub repo  : $GITHUB_OWNER/$GITHUB_REPO (owner id $GITHUB_OWNER_ID, repo id $GITHUB_REPO_ID)"

# ── 1. EKS cluster and managed node group ────────────────────
say "1/9  EKS cluster and node group"
if aws eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
  info "cluster already exists"
else
  eksctl create cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" \
    --nodegroup-name "$NODEGROUP_NAME" --managed --node-type "$NODE_TYPE" \
    --node-ami-family AmazonLinux2023 --nodes "$NODE_COUNT" --nodes-min "$NODE_MIN" --nodes-max "$NODE_MAX"
fi
aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null
# Access entries (step 7) need the API authentication mode.
MODE=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.accessConfig.authenticationMode --output text)
if [[ "$MODE" == "CONFIG_MAP" ]]; then
  aws eks update-cluster-config --name "$CLUSTER_NAME" --access-config authenticationMode=API_AND_CONFIG_MAP >/dev/null
  info "switching authentication mode to API_AND_CONFIG_MAP"; sleep 60
fi
eksctl utils associate-iam-oidc-provider --cluster "$CLUSTER_NAME" --region "$AWS_REGION" --approve
VPC_ID=$(aws eks describe-cluster --name "$CLUSTER_NAME" --query cluster.resourcesVpcConfig.vpcId --output text)

# ── 2. EBS CSI driver (persistent volumes for MySQL and monitoring) ──
say "2/9  EBS CSI driver and gp3 StorageClass"
eksctl create iamserviceaccount --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
  --namespace kube-system --name ebs-csi-controller-sa --role-name AmazonEKS_EBS_CSI_DriverRole --role-only \
  --attach-policy-arn arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy --approve
if ! aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver >/dev/null 2>&1; then
  aws eks create-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver \
    --service-account-role-arn "arn:aws:iam::$ACCOUNT_ID:role/AmazonEKS_EBS_CSI_DriverRole" --resolve-conflicts OVERWRITE >/dev/null
fi
aws eks wait addon-active --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver
kubectl apply -f k8-manifests/cluster/storage-class.yaml

# ── 3. AWS Load Balancer Controller (turns Ingresses into ALBs) ──
say "3/9  AWS Load Balancer Controller"
LBC_POLICY_ARN="arn:aws:iam::$ACCOUNT_ID:policy/AWSLoadBalancerControllerIAMPolicy"
aws iam get-policy --policy-arn "$LBC_POLICY_ARN" >/dev/null 2>&1 ||
  aws iam create-policy --policy-name AWSLoadBalancerControllerIAMPolicy \
    --policy-document file://iam/aws-load-balancer-controller-policy.json >/dev/null
eksctl create iamserviceaccount --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
  --namespace kube-system --name aws-load-balancer-controller \
  --attach-policy-arn "$LBC_POLICY_ARN" --override-existing-serviceaccounts --approve
helm repo add eks https://aws.github.io/eks-charts >/dev/null 2>&1 || true
helm repo update eks >/dev/null
helm upgrade --install aws-load-balancer-controller eks/aws-load-balancer-controller -n kube-system \
  --set clusterName="$CLUSTER_NAME" --set region="$AWS_REGION" --set vpcId="$VPC_ID" \
  --set serviceAccount.create=false --set serviceAccount.name=aws-load-balancer-controller \
  ${LBC_CHART_VERSION:+--version "$LBC_CHART_VERSION"} --wait

# ── 4. External Secrets Operator ─────────────────────────────
say "4/9  External Secrets Operator"
helm repo add external-secrets https://charts.external-secrets.io >/dev/null 2>&1 || true
helm repo update external-secrets >/dev/null
helm upgrade --install external-secrets external-secrets/external-secrets \
  -n external-secrets --create-namespace --set installCRDs=true --wait

# ── 5. MySQL credentials in Secrets Manager ──────────────────
say "5/9  MySQL credentials in Secrets Manager (values come from your environment)"
for env in "${ENVIRONMENTS[@]}"; do
  secret=$(MYSQL_DATABASE="$MYSQL_DATABASE" MYSQL_USER="$MYSQL_USER" "$PY" -c "
import json, os
print(json.dumps({
  'MYSQL_ROOT_PASSWORD': os.environ['MYSQL_ROOT_PASSWORD'],
  'MYSQL_DATABASE': os.environ['MYSQL_DATABASE'],
  'MYSQL_USER': os.environ['MYSQL_USER'],
  'MYSQL_PASSWORD': os.environ['MYSQL_PASSWORD'],
  'DATABASE_URL': 'mysql://%s:%s@mysql:3306/%s' % (os.environ['MYSQL_USER'], os.environ['MYSQL_PASSWORD'], os.environ['MYSQL_DATABASE']),
}))")
  if aws secretsmanager describe-secret --secret-id "$env/mysql-secret" >/dev/null 2>&1; then
    info "$env/mysql-secret already exists (left unchanged)"
  else
    aws secretsmanager create-secret --name "$env/mysql-secret" --secret-string "$secret" >/dev/null
    info "created $env/mysql-secret"
  fi
done

# ── 6. Per-environment IAM roles for External Secrets ────────
say "6/9  Namespaces and External Secrets IAM roles (each env reads only its own secret)"
for env in "${ENVIRONMENTS[@]}"; do
  kubectl create namespace "$env" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  name="ESOSecretsManager$(upper "$env")ReadPolicy"
  arn="arn:aws:iam::$ACCOUNT_ID:policy/$name"
  if ! aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1; then
    doc=$(sed -e "s/<AWS_ACCOUNT_ID>/$ACCOUNT_ID/" -e "s/us-east-1/$AWS_REGION/" -e "s#secret:prod/#secret:$env/#" \
      iam/eso-secrets-policy.json)
    aws iam create-policy --policy-name "$name" --policy-document "$doc" >/dev/null
  fi
  eksctl create iamserviceaccount --cluster "$CLUSTER_NAME" --region "$AWS_REGION" \
    --namespace "$env" --name "eso-$env-sa" --role-name "eso-$env-secrets-role" \
    --attach-policy-arn "$arn" --override-existing-serviceaccounts --approve
done

# ── 7. GitHub Actions OIDC deploy roles with EKS access ──────
say "7/9  GitHub Actions OIDC provider, deploy roles and EKS access entries"
GH_OIDC_ARN="arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"
aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$GH_OIDC_ARN" >/dev/null 2>&1 ||
  aws iam create-open-id-connect-provider --url https://token.actions.githubusercontent.com --client-id-list sts.amazonaws.com >/dev/null
DESCRIBE_ARN="arn:aws:iam::$ACCOUNT_ID:policy/GitHubActionsEKSDescribeClusterPolicy"
if ! aws iam get-policy --policy-arn "$DESCRIBE_ARN" >/dev/null 2>&1; then
  aws iam create-policy --policy-name GitHubActionsEKSDescribeClusterPolicy --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{\"Sid\": \"EKSDescribeCluster\", \"Effect\": \"Allow\", \"Action\": [\"eks:DescribeCluster\"],
      \"Resource\": \"arn:aws:eks:$AWS_REGION:$ACCOUNT_ID:cluster/$CLUSTER_NAME\"}]}" >/dev/null
fi
for env in "${ENVIRONMENTS[@]}"; do
  branch=$([[ "$env" == prod ]] && echo "$PROD_BRANCH" || echo "$QA_BRANCH")
  role="GitHubActionsEKSDeployRole$(upper "$env")"
  trust="{
    \"Version\": \"2012-10-17\",
    \"Statement\": [{\"Effect\": \"Allow\",
      \"Principal\": {\"Federated\": \"$GH_OIDC_ARN\"},
      \"Action\": \"sts:AssumeRoleWithWebIdentity\",
      \"Condition\": {\"StringEquals\": {
        \"token.actions.githubusercontent.com:aud\": \"sts.amazonaws.com\",
        \"token.actions.githubusercontent.com:sub\": \"repo:$GITHUB_OWNER@$GITHUB_OWNER_ID/$GITHUB_REPO@$GITHUB_REPO_ID:ref:refs/heads/$branch\"}}}]}"
  if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    aws iam update-assume-role-policy --role-name "$role" --policy-document "$trust"
  else
    aws iam create-role --role-name "$role" --assume-role-policy-document "$trust" >/dev/null
  fi
  aws iam attach-role-policy --role-name "$role" --policy-arn "$DESCRIBE_ARN"
  role_arn="arn:aws:iam::$ACCOUNT_ID:role/$role"
  printf -v "ROLE_ARN_$env" '%s' "$role_arn"
  aws eks describe-access-entry --cluster-name "$CLUSTER_NAME" --principal-arn "$role_arn" >/dev/null 2>&1 ||
    aws eks create-access-entry --cluster-name "$CLUSTER_NAME" --principal-arn "$role_arn" >/dev/null
  # Edit rights in its own namespace only.
  aws eks associate-access-policy --cluster-name "$CLUSTER_NAME" --principal-arn "$role_arn" \
    --policy-arn arn:aws:eks::aws:cluster-access-policy/AmazonEKSEditPolicy \
    --access-scope "type=namespace,namespaces=$env" >/dev/null
  info "$role -> branch '$branch', namespace '$env'"
done

# ── 8. Registry credentials and MySQL in each namespace ──────
say "8/9  Docker Hub pull secret and MySQL in qa and prod"
for env in "${ENVIRONMENTS[@]}"; do
  kubectl create secret docker-registry regcred -n "$env" \
    --docker-server=https://index.docker.io/v1/ --docker-username="$DOCKERHUB_USERNAME" \
    --docker-password="$DOCKERHUB_TOKEN" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
  kubectl apply -n "$env" -f "k8-manifests/mysql/$env/"
done
for env in "${ENVIRONMENTS[@]}"; do
  kubectl wait --for=condition=Ready externalsecret/mysql-external-secret -n "$env" --timeout=120s
  kubectl rollout status statefulset/mysql -n "$env" --timeout=300s
done

# ── 9. TLS certificates (optional) ───────────────────────────
say "9/9  ACM certificates"
for pair in "qa:$QA_DOMAIN" "prod:$PROD_DOMAIN"; do
  env=${pair%%:*}; domain=${pair#*:}
  if [[ -z "$domain" ]]; then info "$env: no domain set, skipped"; continue; fi
  arn=$(aws acm list-certificates --query "CertificateSummaryList[?DomainName=='$domain'].CertificateArn | [0]" --output text)
  if [[ "$arn" == "None" || -z "$arn" ]]; then
    arn=$(aws acm request-certificate --domain-name "$domain" --validation-method DNS --query CertificateArn --output text)
    info "$env: requested certificate for $domain. Add its DNS validation record in your DNS provider."
  fi
  info "$env: put this ARN in k8-manifests/$env/app-ingress.yaml -> $arn"
done

# ── Next steps ───────────────────────────────────────────────
NODE_ROLE=$(aws eks describe-nodegroup --cluster-name "$CLUSTER_NAME" --nodegroup-name "$NODEGROUP_NAME" \
  --query nodegroup.nodeRole --output text | sed 's#.*/##')
say "Done. Next steps:"
cat <<EOF
  1. GitHub repo -> Settings -> Secrets and variables -> Actions:
       AWS_ROLE_TO_ASSUME       = $ROLE_ARN_qa
       AWS_PROD_ROLE_TO_ASSUME  = $ROLE_ARN_prod
       DOCKERHUB_TOKEN, SONAR_TOKEN, SONAR_HOST_URL (secrets) and DOCKERHUB_USERNAME (variable)
  2. Put the certificate ARNs into the two app-ingress.yaml files, then push to '$QA_BRANCH' to deploy QA.
  3. Monitoring (PowerShell):
       cd monitoring
       # set \$NODE_ROLE_NAME in deploy.ps1 to: $NODE_ROLE
       \$env:GRAFANA_ADMIN_PASSWORD = "<choose-a-password>"
       .\\deploy.ps1
  4. Tear everything down when finished:  bash scripts/teardown.sh
EOF
