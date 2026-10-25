#!/usr/bin/env bash
# ============================================================
# teardown.sh
# Deletes everything scripts/provision.sh creates, in dependency order:
# load balancers and volumes first (through Kubernetes, so AWS cleans them
# up), then the cluster and VPC, then IAM, secrets and certificates.
#
# DESTRUCTIVE: both MySQL databases and all monitoring data are lost.
# Run from the project root:  bash scripts/teardown.sh
# Safe to re-run if it stops partway.
# ============================================================
set -euo pipefail

# Must match the values used in provision.sh.
AWS_REGION="us-east-1"
CLUSTER_NAME="my-cluster-1"
QA_DOMAIN=""
PROD_DOMAIN=""
LOKI_BUCKET=""                   # S3 bucket from monitoring/deploy.ps1; empty = keep

ENVIRONMENTS=(qa prod)
export AWS_REGION AWS_DEFAULT_REGION="$AWS_REGION"
say()  { printf '\n\033[36m==> %s\033[0m\n' "$*"; }
info() { printf '    %s\n' "$*"; }
upper() { printf '%s' "$1" | tr '[:lower:]' '[:upper:]'; }

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
printf 'This permanently deletes cluster "%s" and all its data in account %s.\nType the cluster name to continue: ' "$CLUSTER_NAME" "$ACCOUNT_ID"
read -r answer
[[ "$answer" == "$CLUSTER_NAME" ]] || { echo "Cancelled."; exit 1; }

if aws eks describe-cluster --name "$CLUSTER_NAME" >/dev/null 2>&1; then
  aws eks update-kubeconfig --name "$CLUSTER_NAME" --region "$AWS_REGION" >/dev/null

  say "1/5  Delete ingresses so the Load Balancer Controller removes the ALBs"
  for ns in "${ENVIRONMENTS[@]}" monitoring; do kubectl delete ingress --all -n "$ns" --ignore-not-found; done
  for _ in $(seq 1 40); do
    n=$(aws elbv2 describe-load-balancers --query "length(LoadBalancers[?starts_with(LoadBalancerName,'k8s-')])" --output text)
    [[ "$n" == "0" ]] && break; info "waiting for $n load balancer(s)..."; sleep 15
  done

  say "2/5  Delete app and monitoring namespaces (their EBS volumes go with them)"
  kubectl delete namespace "${ENVIRONMENTS[@]}" monitoring --ignore-not-found --wait=true --timeout=10m

  say "3/5  Delete the cluster, node group, VPC and eksctl-managed IAM roles (15-20 min)"
  eksctl delete cluster --name "$CLUSTER_NAME" --region "$AWS_REGION" --wait
else
  info "cluster $CLUSTER_NAME not found, skipping steps 1-3"
fi

say "4/5  Delete leftover volumes, IAM roles and policies"
for v in $(aws ec2 describe-volumes --filters Name=status,Values=available Name=tag-key,Values=kubernetes.io/created-for/pvc/name --query 'Volumes[].VolumeId' --output text); do
  aws ec2 delete-volume --volume-id "$v"; info "deleted volume $v"
done
delete_role() {
  local r=$1
  aws iam get-role --role-name "$r" >/dev/null 2>&1 || return 0
  for p in $(aws iam list-attached-role-policies --role-name "$r" --query 'AttachedPolicies[].PolicyArn' --output text); do
    aws iam detach-role-policy --role-name "$r" --policy-arn "$p"; done
  for p in $(aws iam list-role-policies --role-name "$r" --query PolicyNames --output text); do
    aws iam delete-role-policy --role-name "$r" --policy-name "$p"; done
  aws iam delete-role --role-name "$r"; info "deleted role $r"
}
policies=(GitHubActionsEKSDescribeClusterPolicy AWSLoadBalancerControllerIAMPolicy LokiS3Policy)
for env in "${ENVIRONMENTS[@]}"; do
  delete_role "GitHubActionsEKSDeployRole$(upper "$env")"
  delete_role "eso-$env-secrets-role"
  policies+=("ESOSecretsManager$(upper "$env")ReadPolicy")
done
delete_role AmazonEKS_EBS_CSI_DriverRole
for p in "${policies[@]}"; do
  arn="arn:aws:iam::$ACCOUNT_ID:policy/$p"
  aws iam get-policy --policy-arn "$arn" >/dev/null 2>&1 || continue
  for e in $(aws iam list-entities-for-policy --policy-arn "$arn" --query 'PolicyRoles[].RoleName' --output text); do
    aws iam detach-role-policy --role-name "$e" --policy-arn "$arn"; done
  for v in $(aws iam list-policy-versions --policy-arn "$arn" --query 'Versions[?!IsDefaultVersion].VersionId' --output text); do
    aws iam delete-policy-version --policy-arn "$arn" --version-id "$v"; done
  aws iam delete-policy --policy-arn "$arn"; info "deleted policy $p"
done
# The GitHub OIDC provider may be shared with other repos in this account; uncomment to remove it.
# aws iam delete-open-id-connect-provider --open-id-connect-provider-arn "arn:aws:iam::$ACCOUNT_ID:oidc-provider/token.actions.githubusercontent.com"

say "5/5  Delete secrets, certificates and the Loki bucket"
for env in "${ENVIRONMENTS[@]}"; do
  aws secretsmanager delete-secret --secret-id "$env/mysql-secret" --force-delete-without-recovery >/dev/null 2>&1 &&
    info "deleted $env/mysql-secret" || true
done
for domain in "$QA_DOMAIN" "$PROD_DOMAIN"; do
  [[ -n "$domain" ]] || continue
  for c in $(aws acm list-certificates --query "CertificateSummaryList[?DomainName=='$domain'].CertificateArn" --output text); do
    aws acm delete-certificate --certificate-arn "$c"; info "deleted certificate for $domain"; done
done
[[ -n "$LOKI_BUCKET" ]] && aws s3 rb "s3://$LOKI_BUCKET" --force

say "Done. Check the console for anything created outside these scripts (DNS zones, other EC2 instances)."
