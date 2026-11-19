#!/usr/bin/env bash
# Remove everything the add-ons created OUTSIDE terraform, so `terraform destroy` can succeed.
# Run this BEFORE terraform destroy (it never runs destroy itself).
#
# Why: the ALB and its target groups are created by the AWS Load Balancer Controller from the
# api-gateway Ingress, not by terraform. If they still exist, destroy fails on the VPC/subnets/ALB SG
# and the ALB keeps billing. The controller must stay running until they are gone.
#
# Order:
#   1. delete the root app petclinic-dev, then the 8 child Applications (their finalizer deletes the
#      Helm resources, including the api-gateway Ingress)
#   2. delete the api-gateway Ingress directly (covers the case where ArgoCD is already gone)
#   3. wait until the ALB and the controller's target groups are really gone (aws elbv2)
#   4. uninstall kube-prometheus-stack, Zipkin, External Secrets, ArgoCD and, last, the LB controller
#   5. print anything that is still left
#
# Prints no secrets; masks the AWS account ID. Idempotent.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TF_DIR="$ROOT/terraform/environments/dev"
ARGOCD_VERSION="v3.6.2"
ARGOCD_INSTALL_URL="https://raw.githubusercontent.com/argoproj/argo-cd/${ARGOCD_VERSION}/manifests/install.yaml"
ALB_WAIT_SECONDS=600

log()  { printf '\n\033[1;34m==> %s\033[0m\n' "$*"; }
ok()   { printf '    \033[32mok\033[0m  %s\n' "$*"; }
warn() { printf '    \033[33mwarn\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31mERROR:\033[0m %s\n' "$*" >&2; exit 1; }
mask() { sed -E 's/[0-9]{12}/<account>/g'; }

for bin in aws kubectl helm terraform; do
  command -v "$bin" >/dev/null || die "$bin not found on PATH"
done

CLUSTER="${CLUSTER:-$(terraform -chdir="$TF_DIR" output -raw eks_cluster_name 2>/dev/null || true)}"
REGION="${REGION:-$(terraform -chdir="$TF_DIR" output -raw aws_region 2>/dev/null || true)}"
[[ -n "$CLUSTER" && -n "$REGION" ]] || die "cannot read cluster/region from terraform outputs (or set CLUSTER and REGION)"
ALB_NAME="${CLUSTER}-alb"   # helm-values/dev.yaml: alb.ingress.kubernetes.io/load-balancer-name
ok "cluster=$CLUSTER region=$REGION alb=$ALB_NAME"

k()  { kubectl --context "$CLUSTER" "$@"; }
hm() { helm --kube-context "$CLUSTER" "$@"; }

CLUSTER_UP=0
if aws eks describe-cluster --region "$REGION" --name "$CLUSTER" >/dev/null 2>&1; then
  aws eks update-kubeconfig --region "$REGION" --name "$CLUSTER" --alias "$CLUSTER" >/dev/null
  k get --raw /readyz >/dev/null 2>&1 && CLUSTER_UP=1
fi
((CLUSTER_UP)) || warn "cluster not reachable - skipping Kubernetes steps, checking AWS leftovers only"

has_crd() { k get crd "$1" >/dev/null 2>&1; }

# --- AWS helpers (aws elbv2 / ec2) -------------------------------------------
alb_state() { # prints the ALB state, or "gone"; fails on any other AWS error
  local out
  if out="$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
      --query 'LoadBalancers[0].State.Code' --output text 2>&1)"; then
    echo "$out"
  elif grep -q LoadBalancerNotFound <<<"$out"; then
    echo gone
  else
    die "aws elbv2 describe-load-balancers failed: $(mask <<<"$out")"
  fi
}

controller_target_groups() { # ARNs of target groups tagged by the controller for this cluster
  local arn tag
  for arn in $(aws elbv2 describe-target-groups --region "$REGION" \
      --query "TargetGroups[?starts_with(TargetGroupName, 'k8s-')].TargetGroupArn" --output text); do
    [[ "$arn" == "None" ]] && continue
    tag="$(aws elbv2 describe-tags --region "$REGION" --resource-arns "$arn" \
      --query "TagDescriptions[0].Tags[?Key=='elbv2.k8s.aws/cluster'].Value | [0]" --output text 2>/dev/null || true)"
    [[ "$tag" == "$CLUSTER" ]] && echo "$arn"
  done
  return 0
}

controller_security_groups() {
  aws ec2 describe-security-groups --region "$REGION" \
    --filters "Name=tag:elbv2.k8s.aws/cluster,Values=$CLUSTER" \
    --query 'SecurityGroups[].GroupId' --output text
}

if ((CLUSTER_UP)); then
  # --- 1. ArgoCD applications --------------------------------------------------
  log "1. Deleting ArgoCD applications"
  if has_crd applications.argoproj.io; then
    # Root first (no finalizer: its children are left in place), so nothing re-creates them.
    k -n argocd delete applications.argoproj.io petclinic-dev --ignore-not-found --timeout=2m
    # Children carry resources-finalizer.argocd.argoproj.io: deleting them deletes their resources.
    k -n argocd delete applications.argoproj.io -l app.kubernetes.io/part-of=petclinic,environment=dev \
      --ignore-not-found --timeout=10m
    ok "petclinic Applications deleted"
  else
    ok "ArgoCD not installed - nothing to delete"
  fi

  # --- 2. Ingress ----------------------------------------------------------------
  log "2. Deleting the api-gateway Ingress (the controller then deletes the ALB)"
  k -n petclinic-dev delete ingress api-gateway --ignore-not-found --timeout=5m
  ok "Ingress gone"
fi

# --- 3. wait for the ALB and target groups -------------------------------------
log "3. Waiting for the ALB and its target groups to be deleted (max ${ALB_WAIT_SECONDS}s)"
deadline=$((SECONDS + ALB_WAIT_SECONDS))
while :; do
  state="$(alb_state)"
  tgs="$(controller_target_groups)"
  tg_count="$(grep -c . <<<"$tgs" || true)"
  printf '    ALB %s: %s | controller target groups: %s\n' "$ALB_NAME" "$state" "$tg_count"
  [[ "$state" == "gone" && "$tg_count" -eq 0 ]] && break
  if ((SECONDS > deadline)); then
    warn "ALB/target groups still exist after ${ALB_WAIT_SECONDS}s. NOT uninstalling the LB controller."
    warn "Check: kubectl -n kube-system logs deploy/aws-load-balancer-controller --tail=50"
    printf '%s\n' "$tgs" | mask | sed 's/^/      /'
    exit 1
  fi
  sleep 15
done
ok "ALB and target groups are gone"

if ((CLUSTER_UP)); then
  # --- 4. uninstall ------------------------------------------------------------
  log "4. Uninstalling add-ons"
  hm uninstall kube-prometheus-stack -n monitoring --ignore-not-found --wait --timeout 5m
  k -n monitoring delete configmap/petclinic-dashboard secret/grafana-admin --ignore-not-found

  k delete -f "$ROOT/k8s/base/observability/zipkin.yaml" --ignore-not-found --timeout=3m
  k delete -f "$ROOT/k8s/base/tracing-server.yaml" --ignore-not-found

  if has_crd externalsecrets.external-secrets.io; then
    k delete -f "$ROOT/k8s/base/external-secrets/rds-credentials.yaml" --ignore-not-found
    k delete -f "$ROOT/k8s/base/external-secrets/cluster-secret-store.yaml" --ignore-not-found
  fi
  hm uninstall external-secrets -n external-secrets --ignore-not-found --wait --timeout 5m

  if k get namespace argocd >/dev/null 2>&1; then
    k delete -n argocd -f "$ARGOCD_INSTALL_URL" --ignore-not-found --timeout=5m >/dev/null
    ok "ArgoCD $ARGOCD_VERSION removed"
  fi

  # Last: only now is it safe to remove the controller.
  hm uninstall aws-load-balancer-controller -n kube-system --ignore-not-found --wait --timeout 5m
fi

# --- 5. leftovers ------------------------------------------------------------
log "5. What is still left"
left=0
if ((CLUSTER_UP)); then
  rel="$(hm list -A -q | grep -E '^(aws-load-balancer-controller|external-secrets|kube-prometheus-stack)$' || true)"
  [[ -n "$rel" ]] && { warn "helm releases: $(tr '\n' ' ' <<<"$rel")"; left=1; } || ok "helm releases: none of ours"
  ing="$(k get ingress -A --no-headers 2>/dev/null || true)"
  [[ -n "$ing" ]] && { warn "ingresses:"; printf '%s\n' "$ing" | sed 's/^/      /'; left=1; } || ok "ingresses: none"
  lbsvc="$(k get svc -A -o jsonpath='{range .items[?(@.spec.type=="LoadBalancer")]}{.metadata.namespace}/{.metadata.name}{"\n"}{end}')"
  [[ -n "$lbsvc" ]] && { warn "Services type=LoadBalancer: $lbsvc"; left=1; } || ok "Services type=LoadBalancer: none"
  if has_crd applications.argoproj.io; then
    apps="$(k get applications.argoproj.io -A --no-headers 2>/dev/null || true)"
    [[ -n "$apps" ]] && { warn "ArgoCD applications:"; printf '%s\n' "$apps" | sed 's/^/      /'; left=1; }
  fi
  pvc="$(k get pvc -A --no-headers 2>/dev/null || true)"
  [[ -n "$pvc" ]] && { warn "PVCs (would leave EBS volumes):"; printf '%s\n' "$pvc" | sed 's/^/      /'; left=1; } || ok "PVCs: none"
fi
[[ "$(alb_state)" == "gone" ]] && ok "ALB $ALB_NAME: gone" || { warn "ALB $ALB_NAME still exists"; left=1; }
tgs="$(controller_target_groups)"
[[ -z "$tgs" ]] && ok "controller target groups: none" || { warn "target groups:"; printf '%s\n' "$tgs" | mask | sed 's/^/      /'; left=1; }
sgs="$(controller_security_groups)"
[[ -z "$sgs" || "$sgs" == "None" ]] && ok "controller security groups: none" || { warn "controller security groups: $sgs"; left=1; }
vols="$(aws ec2 describe-volumes --region "$REGION" --filters "Name=tag-key,Values=kubernetes.io/cluster/$CLUSTER" \
  "Name=status,Values=available" --query 'Volumes[].VolumeId' --output text)"
[[ -z "$vols" || "$vols" == "None" ]] && ok "detached cluster EBS volumes: none" || { warn "detached EBS volumes: $vols"; left=1; }

echo
if ((left)); then
  warn "Something is still left (see above). Fix it before terraform destroy."
  exit 2
fi
ok "Nothing left from the add-ons. Next (needs your approval): terraform destroy in terraform/environments/dev"
