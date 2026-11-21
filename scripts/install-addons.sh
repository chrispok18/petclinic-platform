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
# AWS credentials for that account, and aws, kubectl, helm, terraform, openssl, jq on PATH.
#
# Idempotent: safe to re-run; every step is an upgrade/apply. Prints no secrets and masks the
# AWS account ID. All kubectl/helm calls are pinned to the petclinic-dev kube context.
#
# Slow-link hardening (e.g. far from eu-central-1):
#   - Charts are pulled once (with retries) into $CHART_CACHE and installed from the local .tgz;
#     kube-prometheus-stack comes from OCI (ghcr.io), avoiding its multi-MB index.yaml.
#   - helm: --disable-openapi-validation (no OpenAPI schema download), --timeout $HELM_TIMEOUT,
#     up to $HELM_ATTEMPTS attempts. A stuck release is cleared before each retry: never-deployed
#     failed/pending releases are uninstalled; a pending upgrade of a working release is rolled back
#     (uninstalling e.g. ESO would delete its CRDs and every synced Secret).
#   - A release already deployed with the same chart + values (hash in the release description)
#     is skipped after one `helm status` call (no upgrade), so re-runs pass steps a-d quickly.
#   - kubectl: --request-timeout=$KUBECTL_REQUEST_TIMEOUT on every call except long-running
#     watches (rollout status / wait), which carry their own --timeout.
#   - kube-prometheus-stack CRDs are applied separately (server-side, per file, with retries) and
#     skipped when all are present at the chart's operator version; the chart uses --skip-crds.
#
# Usage: scripts/install-addons.sh [--no-wait-apps]
#   Tunables (env): HELM_TIMEOUT=15m HELM_ATTEMPTS=3 KUBECTL_REQUEST_TIMEOUT=120s CHART_CACHE=...
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform/environments/dev"

LBC_CHART_VERSION="3.6.3"
ESO_CHART_VERSION="2.15.0"
KPS_CHART_VERSION="93.4.1"
KPS_CHART_REF="oci://ghcr.io/prometheus-community/charts/kube-prometheus-stack"
ARGOCD_VERSION="v3.6.2"
ARGOCD_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"

HELM_TIMEOUT="${HELM_TIMEOUT:-15m}"
HELM_ATTEMPTS="${HELM_ATTEMPTS:-3}"
KUBECTL_REQUEST_TIMEOUT="${KUBECTL_REQUEST_TIMEOUT:-120s}"
CHART_CACHE="${CHART_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/petclinic-addons/charts}"

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

for bin in aws kubectl helm terraform openssl jq tar sha256sum; do
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

k()  { kubectl --context "$CLUSTER" --request-timeout="$KUBECTL_REQUEST_TIMEOUT" "$@"; }
kw() { kubectl --context "$CLUSTER" "$@"; }   # watches (rollout status / wait): own --timeout
hm() { helm --kube-context "$CLUSTER" "$@"; }

# fetch_chart <name> <version> <oci://ref | repo-url>: pull once into $CHART_CACHE, print .tgz path.
fetch_chart() {
  local name=$1 ver=$2 src=$3 tgz="$CHART_CACHE/$1-$2.tgz" tmp
  if [[ ! -s "$tgz" ]]; then
    mkdir -p "$CHART_CACHE"
    tmp="$(mktemp -d "$CHART_CACHE/.pull.XXXXXX")"
    if [[ "$src" == oci://* ]]; then
      retry 3 20 helm pull "$src" --version "$ver" -d "$tmp" >&2 || die "could not pull $src $ver"
    else
      retry 3 20 helm pull "$name" --repo "$src" --version "$ver" -d "$tmp" >&2 || die "could not pull $name $ver from $src"
    fi
    mv "$tmp/$name-$ver.tgz" "$tgz"
    rmdir "$tmp"
  fi
  printf '%s' "$tgz"
}

release_status() { hm status "$1" -n "$2" -o json 2>/dev/null | jq -r "${3:-.info.status} // empty" || true; }

# clear_stuck_release <release> <namespace>: make a failed/pending release retryable.
clear_stuck_release() {
  local rel=$1 ns=$2 st ever
  st="$(release_status "$rel" "$ns")"
  case "$st" in
    failed | pending-install | pending-upgrade | pending-rollback | uninstalling) ;;
    *) return 0 ;;
  esac
  ever="$(hm history "$rel" -n "$ns" -o json 2>/dev/null \
    | jq '[.[] | select(.status == "deployed" or .status == "superseded")] | length' || echo 0)"
  if [[ "$ever" -eq 0 ]]; then
    warn "release $ns/$rel is '$st' and was never deployed: uninstalling before retry"
    hm uninstall "$rel" -n "$ns" --wait --timeout "$HELM_TIMEOUT" >/dev/null \
      || warn "uninstall of $ns/$rel failed; the retry may still succeed"
  elif [[ "$st" == pending-* ]]; then
    warn "release $ns/$rel is '$st' (was deployed before): rolling back to the last good revision"
    hm rollback "$rel" -n "$ns" --wait --timeout "$HELM_TIMEOUT" >/dev/null \
      || warn "rollback of $ns/$rel failed; the retry may still succeed"
  fi # failed after an earlier deploy: helm upgrade handles it directly
}

# helm_install <release> <namespace> <chart.tgz> [helm args...]
# Skips when already deployed with the same chart + args + values files; otherwise upgrade --install
# with up to $HELM_ATTEMPTS attempts, clearing a stuck release before each one.
helm_install() {
  local rel=$1 ns=$2 chart=$3 a prev="" cfg i
  shift 3
  cfg="$( {
    printf '%s\n' "$rel" "$ns" "${chart##*/}"
    for a in "$@"; do
      printf '%s\n' "$a"
      [[ "$prev" == "-f" || "$prev" == "--values" ]] && cat "$a"
      prev=$a
    done
  } | sha256sum | cut -c1-16)"
  if [[ "$(release_status "$rel" "$ns")" == deployed \
     && "$(release_status "$rel" "$ns" .info.description)" == "petclinic-addons cfg=$cfg" ]]; then
    ok "$ns/$rel already deployed with this chart + values (cfg $cfg): skipped"
    return 0
  fi
  for ((i = 1; i <= HELM_ATTEMPTS; i++)); do
    clear_stuck_release "$rel" "$ns"
    if hm upgrade --install "$rel" "$chart" --namespace "$ns" "$@" \
      --disable-openapi-validation --wait --timeout "$HELM_TIMEOUT" \
      --description "petclinic-addons cfg=$cfg" >/dev/null; then
      ok "$ns/$rel deployed (cfg $cfg)"
      return 0
    fi
    ((i < HELM_ATTEMPTS)) && { warn "helm $rel attempt $i/$HELM_ATTEMPTS failed, retrying in 30s"; sleep 30; }
  done
  die "helm upgrade --install $ns/$rel failed after $HELM_ATTEMPTS attempts"
}

log "Updating kubeconfig (context alias: $CLUSTER)"
aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --alias "$CLUSTER" >/dev/null
k get nodes -o wide --no-headers | awk '{printf "    node %-45s %s %s\n", $1, $2, $5}'

# --- a. namespaces -----------------------------------------------------------
log "a. Namespaces (k8s/base/namespaces.yaml)"
retry 3 10 k apply -f "$ROOT/k8s/base/namespaces.yaml"

# --- b. AWS Load Balancer Controller -----------------------------------------
log "b. AWS Load Balancer Controller $LBC_CHART_VERSION (kube-system)"
LBC_TGZ="$(fetch_chart aws-load-balancer-controller "$LBC_CHART_VERSION" https://aws.github.io/eks-charts)"
helm_install aws-load-balancer-controller kube-system "$LBC_TGZ" \
  -f "$ROOT/k8s/base/addons/aws-load-balancer-controller-values.yaml" \
  --set clusterName="$CLUSTER" \
  --set region="$REGION" \
  --set vpcId="$VPC_ID" \
  --set-string "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$LBC_ROLE_ARN"
kw -n kube-system rollout status deploy/aws-load-balancer-controller --timeout=180s
ok "IngressClass: $(k get ingressclass alb -o jsonpath='{.metadata.name}' 2>/dev/null || echo 'missing!')"

# --- c. External Secrets -----------------------------------------------------
log "c. External Secrets Operator $ESO_CHART_VERSION (external-secrets)"
ESO_TGZ="$(fetch_chart external-secrets "$ESO_CHART_VERSION" https://charts.external-secrets.io)"
helm_install external-secrets external-secrets "$ESO_TGZ" --create-namespace \
  -f "$ROOT/k8s/base/addons/external-secrets-values.yaml" \
  --set-string "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$ESO_ROLE_ARN"
for d in external-secrets external-secrets-webhook external-secrets-cert-controller; do
  kw -n external-secrets rollout status "deploy/$d" --timeout=180s
done

# The validating webhook can need a few seconds after rollout before it accepts requests.
retry 12 10 k apply -f "$ROOT/k8s/base/external-secrets/cluster-secret-store.yaml"
kw wait --for=condition=Ready clustersecretstore/aws-secrets-manager --timeout=180s
retry 3 10 k apply -f "$ROOT/k8s/base/external-secrets/rds-credentials.yaml"
kw -n petclinic-dev wait --for=condition=Ready externalsecret/rds-credentials --timeout=180s
# Show key NAMES only, never values.
ok "secret petclinic-dev/rds-credentials keys: $(k -n petclinic-dev get secret rds-credentials \
  -o go-template='{{range $key, $v := .data}}{{$key}} {{end}}')"
k apply -f "$ROOT/k8s/base/tracing-server.yaml"

# --- d. Zipkin ---------------------------------------------------------------
log "d. Zipkin (tracing)"
retry 3 10 k apply -f "$ROOT/k8s/base/observability/zipkin.yaml"
kw -n tracing rollout status deploy/zipkin --timeout=300s

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

KPS_TGZ="$(fetch_chart kube-prometheus-stack "$KPS_CHART_VERSION" "$KPS_CHART_REF")"

# CRDs first, separately: they are large (slow links time out when helm sends them all at once).
# Server-side apply (too big for the last-applied annotation), one file per request, with retries.
KPS_SRC="$(mktemp -d)"
trap 'rm -r -- "$KPS_SRC"' EXIT
tar -xzf "$KPS_TGZ" -C "$KPS_SRC"
CRD_DIR="$KPS_SRC/kube-prometheus-stack/charts/crds/crds"
[[ -d "$CRD_DIR" ]] || die "CRD directory not found in $KPS_TGZ"
crd_files=("$CRD_DIR"/*.yaml)
crd_ver="$(grep -h 'operator.prometheus.io/version:' "${crd_files[@]}" | awk '{print $2}' | sort -u)"
[[ -n "$crd_ver" && "$crd_ver" != *$'\n'* ]] || die "could not read a single operator version from the CRDs"
crd_have="$(k get crd -o jsonpath='{range .items[*]}{.metadata.name}={.metadata.annotations.operator\.prometheus\.io/version}{"\n"}{end}' \
  | grep -c "\.monitoring\.coreos\.com=${crd_ver}$" || true)"
if [[ "$crd_have" -eq "${#crd_files[@]}" ]]; then
  ok "prometheus-operator CRDs: all ${#crd_files[@]} present at $crd_ver (skipped)"
else
  log "   applying ${#crd_files[@]} prometheus-operator CRDs ($crd_ver), server-side ($crd_have up to date)"
  for f in "${crd_files[@]}"; do
    retry 3 20 k apply --server-side --force-conflicts -f "$f" >/dev/null || die "CRD apply failed: ${f##*/}"
    ok "${f##*/}"
  done
fi
kw wait --for=condition=Established -f "$CRD_DIR" --timeout=180s >/dev/null

helm_install kube-prometheus-stack monitoring "$KPS_TGZ" --skip-crds \
  -f "$ROOT/k8s/base/observability/kube-prometheus-stack-values.yaml"
for d in kps-operator grafana kube-prometheus-stack-kube-state-metrics; do
  kw -n monitoring rollout status "deploy/$d" --timeout=300s
done
kw -n monitoring rollout status ds/kube-prometheus-stack-prometheus-node-exporter --timeout=300s
wait_exists monitoring statefulset/prometheus-kps-prometheus 180   # created by the operator
kw -n monitoring rollout status statefulset/prometheus-kps-prometheus --timeout=300s

# --- f. ArgoCD ---------------------------------------------------------------
log "f. ArgoCD $ARGOCD_VERSION (argocd)"
k create namespace argocd --dry-run=client -o yaml | k apply -f -
# Server-side apply: the ArgoCD CRDs are too large for the client-side last-applied annotation.
retry 3 30 k apply --server-side --force-conflicts -n argocd -f "$ARGOCD_INSTALL_URL" >/dev/null \
  || die "ArgoCD install manifest apply failed"
ok "applied $ARGOCD_INSTALL_URL"
# Not used in dev (admin login only, no ApplicationSets, no notifications): saves 3 pods / ~150Mi.
k -n argocd scale deploy argocd-dex-server argocd-notifications-controller \
  argocd-applicationset-controller --replicas=0 >/dev/null
for d in argocd-server argocd-repo-server argocd-redis; do
  kw -n argocd rollout status "deploy/$d" --timeout=300s
done
kw -n argocd rollout status statefulset/argocd-application-controller --timeout=300s

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
