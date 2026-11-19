#!/usr/bin/env bash
# Hook: block-destroy.sh (PreToolUse on Bash)
# Purpose: HARD BLOCK on destroying infrastructure or the petclinic workloads.
#   - terraform / terragrunt / tofu destroy, with any global flags (e.g. -chdir=...) before it
#   - terraform apply -destroy (and terragrunt run-all/run --all destroy)
#   - kubectl delete of namespaces, deployments, services, ingresses, secrets (and "all")
#     in petclinic-dev or petclinic-prod, regardless of flag order (-n/--context before delete),
#     with -A/--all-namespaces, or with NO namespace (the current context could be petclinic-*)
#   - kubectl delete -f/-k whose manifests reference petclinic-dev/prod, or cannot be verified
# Why: destroy/delete is irreversible (VPC, EKS, RDS, the app). CLAUDE.md rule 7.
# How: parses the command with lib/command-parse.sh and exits 2 to deny.
#      Fails CLOSED (exit 2) if jq is missing, the input is unreadable, or anything errors.
# Not covered: indirection like `T=terraform; $T destroy` -> permissions.deny is a second layer.

set -Eeuo pipefail
HOOK_NAME="block-destroy"
fail_closed() { echo "BLOCKED by $HOOK_NAME: $1 - failing closed." >&2; exit 2; }
trap 'fail_closed "unexpected error at line $LINENO"' ERR

command -v jq >/dev/null 2>&1 || fail_closed "jq is not installed (sudo apt install jq), so the command cannot be inspected"
INPUT=$(cat)
COMMAND=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null) || fail_closed "tool input is not valid JSON"
[[ -n $COMMAND ]] || exit 0

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/command-parse.sh
source "$HOOK_DIR/lib/command-parse.sh" || fail_closed "cannot load $HOOK_DIR/lib/command-parse.sh"

REASON=""
PROTECTED_NS_RE='^petclinic-(dev|prod)$'

# --- terraform / terragrunt / tofu --------------------------------------------
tf_destroy_cb() {
  local bin=${1##*/}
  shift
  if [[ ! $bin =~ ^(terraform|terragrunt|tofu)$ ]]; then return 1; fi
  local sub="" t rest=()
  while (($#)); do
    t=$1
    shift
    if [[ -z $sub && $t != -* ]]; then sub=$t; continue; fi
    if [[ -n $sub ]]; then rest+=("$t"); fi
  done
  if [[ $sub == destroy ]]; then REASON="'$bin destroy'"; return 0; fi
  if [[ $bin == terragrunt && ($sub == run-all || $sub == run) ]]; then
    for t in "${rest[@]}"; do
      if [[ $t == destroy ]]; then REASON="'terragrunt $sub ... destroy'"; return 0; fi
    done
  fi
  if [[ $sub == apply ]]; then
    for t in "${rest[@]}"; do
      if [[ $t =~ ^--?destroy(=true)?$ ]]; then REASON="'$bin apply -destroy' (same as destroy)"; return 0; fi
    done
  fi
  return 1
}

# --- kubectl delete ------------------------------------------------------------
k_type_protected() { # <type> -> 0 if namespace/deployment/service/ingress/secret/all
  local ty=${1%%.*}
  ty=${ty,,}
  [[ $ty =~ ^(namespaces?|ns|deployments?|deploy|services?|svc|ingress(es)?|ing|secrets?|all)$ ]]
}
k_type_is_ns() { local ty=${1%%.*}; ty=${ty,,}; [[ $ty =~ ^(namespaces?|ns)$ ]]; }

k_file_check() { # <file-or-dir-or-url> <namespace-flag> -> 0 (= block) with REASON set
  local src=$1 ns=$2 path
  if [[ -z $src || $src == "-" || $src == *"://"* ]]; then
    REASON="'kubectl delete -f ${src:-<stdin>}' (manifest cannot be verified)"; return 0
  fi
  path=$src
  if [[ ! -e $path && -n ${CLAUDE_PROJECT_DIR:-} && -e $CLAUDE_PROJECT_DIR/$src ]]; then path=$CLAUDE_PROJECT_DIR/$src; fi
  if [[ ! -r $path ]]; then
    REASON="'kubectl delete -f $src' (file not found from the hook's directory, cannot be verified)"; return 0
  fi
  if grep -rqE 'petclinic-(dev|prod)' "$path"; then
    REASON="'kubectl delete -f $src' (manifest references petclinic-dev/prod)"; return 0
  fi
  if [[ -z $ns ]] && ! grep -rqE '^[[:space:]]*namespace:' "$path"; then
    REASON="'kubectl delete -f $src' without -n (target namespace unknown)"; return 0
  fi
  return 1
}

k_delete_cb() {
  if [[ ${1##*/} != kubectl ]]; then return 1; fi
  shift
  local ns="" allns=0 all=0 seen=0 t f
  local files=() targets=()
  while (($#)); do
    t=$1
    shift
    case $t in
      -n | --namespace) ns=${1:-}; if (($#)); then shift; fi ;;
      --namespace=* | -n=*) ns=${t#*=} ;;
      -A | --all-namespaces | --all-namespaces=true) allns=1 ;;
      --all | --all=true) all=1 ;;
      -f | --filename | -k | --kustomize) files+=("${1:-}"); if (($#)); then shift; fi ;;
      --filename=* | --kustomize=* | -f=* | -k=*) files+=("${t#*=}") ;;
      --context | --cluster | --user | -s | --server | --kubeconfig | --token | --as | --as-group | \
        -l | --selector | -o | --output | --field-selector | --request-timeout | \
        --certificate-authority | --client-certificate | --client-key | --tls-server-name)
        if (($#)); then shift; fi
        ;;
      --*) ;;
      -n?*) ns=${t#-n} ;;
      -f?*) files+=("${t#-f}") ;;
      -*) ;;
      *)
        if ((seen)); then
          targets+=("$t")
        elif [[ $t == delete ]]; then
          seen=1
        else
          return 1 # first verb is not delete (get, apply, logs, ...)
        fi
        ;;
    esac
  done
  if ((!seen)); then return 1; fi

  # Expand targets: "deploy,svc", "deploy/x", "namespace/petclinic-dev"
  local types=() names=() part tt
  for t in "${targets[@]}"; do
    if [[ $t == */* ]]; then
      types+=("${t%%/*}")
      names+=("${t#*/}")
    else
      IFS=',' read -ra part <<<"$t"
      for tt in "${part[@]}"; do types+=("$tt"); names+=("$tt"); done
    fi
  done

  # 1. Deleting the namespace itself
  for tt in "${types[@]}"; do
    if k_type_is_ns "$tt"; then
      for t in "${names[@]}"; do
        if [[ $t =~ $PROTECTED_NS_RE ]]; then REASON="'kubectl delete namespace $t'"; return 0; fi
      done
      if ((all)); then REASON="'kubectl delete namespace --all'"; return 0; fi
    fi
  done

  # 2. Protected resource types in a protected (or unknown / every) namespace
  local prot=""
  for tt in "${types[@]}"; do
    if k_type_protected "$tt" && ! k_type_is_ns "$tt"; then prot=$tt; break; fi
  done
  if [[ -n $prot ]]; then
    if [[ $ns =~ $PROTECTED_NS_RE ]]; then REASON="'kubectl delete $prot' in $ns"; return 0; fi
    if ((allns)); then REASON="'kubectl delete $prot' across all namespaces (-A)"; return 0; fi
    if [[ -z $ns ]]; then
      REASON="'kubectl delete $prot' without -n (the current context could be petclinic-dev/prod; pass -n explicitly)"
      return 0
    fi
  fi

  # 3. Manifest-based deletes
  if ((${#files[@]})); then
    if [[ $ns =~ $PROTECTED_NS_RE ]]; then REASON="'kubectl delete -f ...' in $ns"; return 0; fi
    if ((allns)); then REASON="'kubectl delete -f ...' across all namespaces"; return 0; fi
    for f in "${files[@]}"; do
      if k_file_check "$f" "$ns"; then return 0; fi
    done
  fi
  return 1
}

if hp_any "$COMMAND" tf_destroy_cb; then
  {
    echo "BLOCKED: $REASON is not allowed via Claude Code."
    echo ""
    echo "Destroying infrastructure must be done manually with explicit human oversight:"
    echo "  1. Run scripts/teardown-addons.sh, then 'terraform plan -destroy' to review"
    echo "  2. Review the plan carefully"
    echo "  3. Run 'terraform destroy' yourself in your terminal (not via Claude)"
  } >&2
  exit 2
fi

if hp_any "$COMMAND" k_delete_cb; then
  {
    echo "BLOCKED: $REASON is not allowed via Claude Code."
    echo ""
    echo "Deleting petclinic namespaces, deployments, services, ingresses or secrets causes downtime"
    echo "or data loss. If intentional, run it yourself in your terminal after checking:"
    echo "  kubectl get <type> -n <namespace>"
  } >&2
  exit 2
fi

exit 0
