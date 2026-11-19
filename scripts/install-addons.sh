#!/usr/bin/env bash
# Install the dev cluster add-ons in dependency order and hand over to ArgoCD.
#
#   a. k8s/base/namespaces.yaml                      (petclinic-dev + PSA labels)
#   b. AWS Load Balancer Controller   chart 3.6.3     (kube-system, IRSA)
#   c. External Secrets Operator      chart 2.15.0    (external-secrets, IRSA)
#      + ClusterSecretStore, rds-credentials ExternalSecret, tracing-server alias
#   d. Zipkin                         openzipkin/zipkin:3.6.1 (tracing)
#   e. kube-prometheus-stack          chart 93.4.1    (monitoring; Grafana + Petclinic dashboard)
#   f. ArgoCD                         v3.6.2          (argocd) + Application health patch + root app
#
# Prerequisites: `terraform apply` done in terraform/environments/dev (EKS, RDS, IRSA roles exist),
# AWS credentials for that account, and aws, kubectl, helm, terraform, openssl on PATH.
#
# Idempotent: safe to re-run; every step is an upgrade/apply. Prints no secrets and masks the
# AWS account ID. All kubectl/helm calls are pinned to the petclinic-dev kube context.
#
# Usage: scripts/install-addons.sh [--no-wait-apps]
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform/environments/dev"

LBC_CHART_VERSION="3.6.3"
ESO_CHART_VERSION="2.15.0"
KPS_CHART_VERSION="93.4.1"
ARGOCD_VERSION="v3.6.2"
ARGOCD_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

WAIT_APPS=1
[[ "${1:-}" == "--no-wait-apps" ]] && WAIT_APPS=0

# --- helpers -----------------------------------------------------------------
log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
mask() { sed -E 's/[0-9]{12}/<account>/g'; }

retry() { # retry <attempts> <sleep> <cmd...>
  local n=$1 d=$2 i; shift 2
  for ((i = 1; i <= n; i++)); do
    "$@" && return 0
    ((i < n)) && { warn "attempt $i/$n failed, retrying in ${d}s"; sleep "$d"; }
  done
  return 1
}

wait_exists() { # wait_exists <namespace> <kind/name> <timeout-seconds>
  local ns=$1 res=$2 t=$3 i
  for ((i = 0; i < t; i += 5)); do
    k -n "$ns" get "$res" >/dev/null 2>&1 && return 0
    sleep 5
  done
  die "$ns/$res did not appear within ${t}s"
}

for bin in aws kubectl helm terraform openssl; do
  command -v "$bin" >/dev/null || die "$bin not found on PATH"
done

tf_out() {
  terraform -chdir="$TF_DIR" output -raw "$1" 2>/dev/null \
    || die "terraform output '$1' not found - run terraform apply in terraform/environments/dev first"
}

# --- 0. terraform outputs + kubeconfig ---------------------------------------
log "Reading terraform outputs (terraform/environments/dev)"
CLUSTER="$(tf_out eks_cluster_name)"
REGION="$(tf_out aws_region)"
VPC_ID="$(tf_out vpc_id)"
ESO_ROLE_ARN="$(tf_out external_secrets_role_arn)"
LBC_ROLE_ARN="$(tf_out lb_controller_role_arn)"
ok "cluster=$CLUSTER region=$REGION vpc=$VPC_ID"
ok "IRSA roles: ${ESO_ROLE_ARN##*/}, ${LBC_ROLE_ARN##*/}"

k()  { kubectl --context "$CLUSTER" "$@"; }
hm() { helm --kube-context "$CLUSTER" "$@"; }

log "Updating kubeconfig (context alias: $CLUSTER)"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --alias "$CLUSTER" >/dev/null
k get nodes -o wide --no-headers | awk '{printf "    node %-45s %s %s\n", $1, $2, $5}'

# --- a. namespaces -----------------------------------------------------------
log "a. Namespaces (k8s/base/namespaces.yaml)"
k apply -f "$ROOT/k8s/base/namespaces.yaml"

# --- b. AWS Load Balancer Controller -----------------------------------------
log "b. AWS Load Balancer Controller $LBC_CHART_VERSION (kube-system)"
hm upgrade --install aws-load-balancer-controller aws-load-balancer-controller \
  --repo https://aws.github.io/eks-charts --version "$LBC_CHART_VERSION" \
  --namespace kube-system \
  -f "$ROOT/k8s/base/addons/aws-load-balancer-controller-values.yaml" \
  --set clusterName="$CLUSTER" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set-string "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$LBC_ROLE_ARN" \
  --wait --timeout 5m >/dev/null
k -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=180s
ok "IngressClass: $(k get ingressclass alb -o jsonpath='{.metadata.name}' 2>/dev/null || echo 'missing!')"

# --- c. External Secrets -----------------------------------------------------
log "c. External Secrets Operator $ESO_CHART_VERSION (external-secrets)"
hm upgrade --install external-secrets external-secrets \
  --repo https://charts.external-secrets.io --version "$ESO_CHART_VERSION" \
  --namespace external-secrets --create-namespace \
  -f "$ROOT/k8s/base/addons/external-secrets-values.yaml" \
  --set-string "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ESO_ROLE_ARN" \
  --wait --timeout 5m >/dev/null
for d in external-secrets external-secrets-webhook external-secrets-cert-controller; do
  k -n external-secrets rollout status "deploy/$d" --timeout=180s
done

# The validating webhook can need a few seconds after rollout before it accepts requests.
retry 12 10 k apply -f "$ROOT/k8s/base/external-secrets/cluster-secret-store.yaml"
k wait --for=condition=Ready clustersecretstore/aws-secrets-manager --timeout=180s
k apply -f "$ROOT/k8s/base/external-secrets/rds-credentials.yaml"
k -n petclinic-dev wait --for=condition=Ready externalsecret/rds-credentials --timeout=180s
# Show key NAMES only, never values.
ok "secret petclinic-dev/rds-credentials keys: $(k -n petclinic-dev get secret rds-credentials \
  -o go-template='{{range $key, $v := .data}}{{$key}} {{end}}')"
k apply -f "$ROOT/k8s/base/tracing-server.yaml"

# --- d. Zipkin ---------------------------------------------------------------
log "d. Zipkin (tracing)"
k apply -f "$ROOT/k8s/base/observability/zipkin.yaml"
k -n tracing rollout status deploy/zipkin --timeout=300s

# --- e. kube-prometheus-stack ------------------------------------------------
log "e. kube-prometheus-stack $KPS_CHART_VERSION (monitoring)"
k create namespace monitoring --dry-run=client -o yaml | k apply -f -

# Grafana admin password: generated once, stored only in this Secret, never printed or in Git.
if k -n monitoring get secret grafana-admin >/dev/null 2>&1; then
  ok "secret monitoring/grafana-admin already exists (kept)"
else
  pw="$(openssl rand -base64 30 | tr -dc 'A-Za-z0-9' | head -c 24)"
  [[ ${#pw} -eq 24 ]] || die "password generation failed"
  printf '%s' "$pw" | k -n monitoring create secret generic grafana-admin \
    --from-literal=admin-user=admin --from-file=admin-password=/dev/stdin >/dev/null
  unset pw
  ok "secret monitoring/grafana-admin created (24-char random password)"
fi

# Spring Petclinic dashboard (from the app repo, docker/grafana) -> ConfigMap for the Grafana sidecar.
k -n monitoring create configmap petclinic-dashboard \
  --from-file=grafana-petclinic-dashboard.json="$ROOT/k8s/base/observability/dashboards/grafana-petclinic-dashboard.json" \
  --dry-run=client -o yaml \
  | k label --local -f - grafana_dashboard=1 app.kubernetes.io/part-of=petclinic \
      app.kubernetes.io/managed-by=kubectl app.kubernetes.io/component=infrastructure -o yaml \
  | k apply -f -

hm upgrade --install kube-prometheus-stack kube-prometheus-stack \
  --repo https://prometheus-community.github.io/helm-charts --version "$KPS_CHART_VERSION" \
  --namespace monitoring \
  -f "$ROOT/k8s/base/observability/kube-prometheus-stack-values.yaml" \
  --wait --timeout 10m >/dev/null
for d in kps-operator grafana kube-prometheus-stack-kube-state-metrics; do
  k -n monitoring rollout status "deploy/$d" --timeout=300s
done
k -n monitoring rollout status ds/kube-prometheus-stack-prometheus-node-exporter --timeout=300s
wait_exists monitoring statefulset/prometheus-kps-prometheus 180   # created by the operator
k -n monitoring rollout status statefulset/prometheus-kps-prometheus --timeout=300s

# --- f. ArgoCD ---------------------------------------------------------------
log "f. ArgoCD $ARGOCD_VERSION (argocd)"
k create namespace argocd --dry-run=client -o yaml | k apply -f -
# Server-side apply: the ArgoCD CRDs are too large for the client-side last-applied annotation.
k apply --server-side --force-conflicts -n argocd -f "$ARGOCD_INSTALL_URL" >/dev/null
ok "applied $ARGOCD_INSTALL_URL"
# Not used in dev (admin login only, no ApplicationSets, no notifications): saves 3 pods / ~150Mi.
k -n argocd scale deploy argocd-dex-server argocd-notifications-controller \
  argocd-applicationset-controller --replicas=0 >/dev/null
for d in argocd-server argocd-repo-server argocd-redis; do
  k -n argocd rollout status "deploy/$d" --timeout=300s
done
k -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

# Application health check: makes the root app wait for each sync wave to be Healthy.
k -n argocd patch configmap argocd-cm --type merge \
  --patch-file "$ROOT/k8s/argocd/install/argocd-cm-application-health.yaml" >/dev/null
ok "argocd-cm: Application health check enabled"

k apply -f "$ROOT/k8s/argocd/root/petclinic-dev.yaml"
ok "root app petclinic-dev applied (config 0 -> discovery 1 -> others 2 -> visits 3)"

# --- wait for the 8 apps -----------------------------------------------------
if ((WAIT_APPS)); then
  log "Waiting for the 8 petclinic Applications to be Synced + Healthy (max 20 min)"
  deadline=$((SECONDS + 1200))
  while :; do
    # Exclude the root app (same labels) so only the 8 service Applications are counted.
    status="$(k -n argocd get applications.argoproj.io \
      -l 'app.kubernetes.io/part-of=petclinic,environment=dev,app.kubernetes.io/name!=petclinic-dev' \
      -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.sync.status}{" "}{.status.health.status}{"\n"}{end}' 2>/dev/null || true)"
    total="$(grep -c . <<<"$status" || true)"
    good="$(grep -c ' Synced Healthy$' <<<"$status" || true)"
    printf '    %s/8 Synced+Healthy (%d apps created)\n' "$good" "$total"
    [[ "$good" -eq 8 ]] && break
    if ((SECONDS > deadline)); then
      warn "not all apps are healthy yet - current state:"
      printf '%s\n' "$status" | sed 's/^/      /'
      warn "check: kubectl -n petclinic-dev get pods ; kubectl -n argocd get applications"
      break
    fi
    sleep 30
  done
fi

# --- summary -----------------------------------------------------------------
log "Done"
k -n argocd get applications.argoproj.io -o wide 2>/dev/null | mask || true
alb="$(k -n petclinic-dev get ingress api-gateway -o jsonpath='{.status.loadBalancer.ingress[0].hostname}' 2>/dev/null || true)"
if [[ -n "$alb" ]]; then
  ok "Petclinic URL: http://$alb  (ALB DNS can take ~2-3 min to resolve)"
else
  warn "api-gateway Ingress has no ALB hostname yet: kubectl -n petclinic-dev get ingress api-gateway -w"
fi
echo "    UIs: scripts/port-forwards.sh start   |   Teardown BEFORE terraform destroy: scripts/teardown-addons.sh"
