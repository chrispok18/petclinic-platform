#!/usr/bin/env bash
# Feed sample PreToolUse JSON to the Claude Code safety hooks and print a PASS/FAIL table.
#
#   scripts/test-hooks.sh                 # test .claude/hooks
#   scripts/test-hooks.sh <hooks-dir>     # test another copy (e.g. the previous version)
#
# Bash commands go through the same chain Claude Code runs for the Bash tool (settings.json order):
# block-destroy, block-dangerous-rm, warn-apply-without-plan, block-secret-commit.
# Result per command, as Claude Code would treat it:
#   BLOCK          some hook exited 2                  -> command denied
#   ASK            a hook returned permissionDecision "ask" -> user is asked
#   ALLOW          all hooks exited 0 with no decision
#   OPEN(exit N)   a hook exited non-0/non-2           -> Claude Code shows stderr and RUNS the command
# Nothing here executes the commands themselves; they are only passed to the hooks as JSON text.
# Exit code: 0 if every case matches its expectation, 1 otherwise.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOOKS="${1:-$ROOT/.claude/hooks}"
export CLAUDE_PROJECT_DIR="$ROOT"
cd "$ROOT"

command -v jq >/dev/null || { echo "jq is required to run the tests" >&2; exit 1; }

BASH_CHAIN=(block-destroy block-dangerous-rm warn-apply-without-plan block-secret-commit)
PASS=0 FAIL=0
ROWS=()

bash_json() { jq -cn --arg c "$1" '{tool_name: "Bash", tool_input: {command: $c}}'; }

# run_chain <json> [hook...] -> prints BLOCK | ASK | ALLOW | OPEN(exit N)
run_chain() {
  local json=$1; shift
  local decision=ALLOW h out rc
  for h in "$@"; do
    out=$(bash "$HOOKS/$h.sh" <<<"$json" 2>/dev/null)
    rc=$?
    if ((rc == 2)); then echo BLOCK; return; fi
    if ((rc != 0)); then decision="OPEN(exit $rc)"; continue; fi
    if [[ -n $out ]] && jq -e '.hookSpecificOutput.permissionDecision == "ask"' >/dev/null 2>&1 <<<"$out"; then
      [[ $decision == ALLOW ]] && decision=ASK
    fi
  done
  echo "$decision"
}

record() { # <expected> <got> <label> <note>
  local res=PASS
  [[ $1 == "$2" ]] || res=FAIL
  [[ $res == PASS ]] && PASS=$((PASS + 1)) || FAIL=$((FAIL + 1))
  ROWS+=("$res"$'\x1f'"$1"$'\x1f'"$2"$'\x1f'"$3"$'\x1f'"$4")
}

case_bash() { # <expected> <command> [note]
  record "$1" "$(run_chain "$(bash_json "$2")" "${BASH_CHAIN[@]}")" "$2" "${3:-}"
}

# --- Bash commands ---------------------------------------------------------------
# Audit H-1 bypasses: must be BLOCKED
case_bash BLOCK "terraform destroy" "baseline"
case_bash BLOCK "terraform -chdir=terraform/environments/dev destroy" "H-1 -chdir bypass"
case_bash BLOCK "terraform -chdir=terraform/environments/dev destroy -auto-approve" "H-1 -chdir bypass"
case_bash BLOCK "cd terraform/environments/dev && terraform destroy -auto-approve" "compound"
case_bash BLOCK "terraform apply -destroy" "apply -destroy"
case_bash BLOCK "terraform -chdir=terraform/environments/dev apply -auto-approve -destroy" "H-1 -chdir + apply -destroy"
case_bash BLOCK "TF_LOG=debug terraform destroy" "env prefix"
case_bash BLOCK "/usr/bin/terraform destroy" "absolute path"
case_bash BLOCK "bash -c \"terraform -chdir=terraform/environments/dev destroy\"" "bash -c wrapper"
case_bash BLOCK "echo yes | terraform destroy" "pipe"
case_bash BLOCK "terragrunt run-all destroy" "terragrunt"
case_bash BLOCK "tofu destroy" "opentofu"
case_bash BLOCK "kubectl delete ns petclinic-dev" "H-1 dev namespace (was prod-only)"
case_bash BLOCK "kubectl delete namespace petclinic-prod" "prod namespace"
case_bash BLOCK "kubectl delete namespace/petclinic-dev" "type/name form"
case_bash BLOCK "kubectl -n petclinic-dev delete secret rds-credentials" "H-1 -n before delete"
case_bash BLOCK "kubectl --context petclinic-dev -n petclinic-dev delete deploy api-gateway" "H-1 --context before delete"
case_bash BLOCK "kubectl -n petclinic-prod delete deploy x" "H-1 audit example"
case_bash BLOCK "kubectl delete svc customers-service --namespace=petclinic-dev" "--namespace="
case_bash BLOCK "kubectl delete -n petclinic-dev ingress api-gateway" "ingress"
case_bash BLOCK "kubectl delete deployment/api-gateway -n petclinic-dev" "type/name"
case_bash BLOCK "kubectl delete deploy,svc -l app.kubernetes.io/part-of=petclinic -n petclinic-dev" "comma list + selector"
case_bash BLOCK "kubectl delete all --all -n petclinic-dev" "all"
case_bash BLOCK "kubectl delete secret rds-credentials" "no -n: context ns unknown"
case_bash BLOCK "kubectl delete deploy --all -A" "all namespaces"
case_bash BLOCK "kubectl delete -f k8s/base/namespaces.yaml" "manifest = petclinic-dev ns"
case_bash BLOCK "git add ." "existing secret-commit block still works"

# Applies: must ASK (previously exit 1 = ran without asking)
case_bash ASK "terraform apply plan.out" "saved plan: still asks"
case_bash ASK "terraform -chdir=terraform/environments/dev apply plan.out" "-chdir apply"
case_bash ASK "terraform apply" "no plan"
case_bash ASK "terraform apply -auto-approve" "H-1 warn hook never asked"

# Normal work: must be ALLOWED
case_bash ALLOW "terraform plan -out plan.out" ""
case_bash ALLOW "terraform -chdir=terraform/environments/dev plan -destroy -out destroy.out" "read-only destroy preview"
case_bash ALLOW "terraform fmt -recursive && terraform validate" ""
case_bash ALLOW "git add helm-values/dev.yaml" ""
case_bash ALLOW "kubectl get pods -n petclinic-dev" ""
case_bash ALLOW "kubectl -n petclinic-dev logs deploy/api-gateway" ""
case_bash ALLOW "kubectl delete pod debug-shell -n petclinic-dev" "pods are not protected"
case_bash ALLOW "kubectl delete deploy test -n default" "other namespace"
case_bash ALLOW "grep -rn \"terraform destroy\" docs/" "mention only (old hook: false positive)"
case_bash ALLOW "git commit -m \"docs: run teardown before terraform destroy\"" "mention only"

# --- MCP Terraform tool -----------------------------------------------------------------
record BLOCK "$(run_chain '{"tool_name":"mcp__terraform__ExecuteTerraformCommand","tool_input":{"command":"destroy"}}' block-mcp-destroy)" \
  "[MCP] ExecuteTerraformCommand destroy" ""
record ALLOW "$(run_chain '{"tool_name":"mcp__terraform__ExecuteTerraformCommand","tool_input":{"command":"plan"}}' block-mcp-destroy)" \
  "[MCP] ExecuteTerraformCommand plan" ""

# --- Fail closed --------------------------------------------------------------------------
# PATH with the usual tools but WITHOUT jq.
NOJQ=$(mktemp -d)
trap 'rm -rf "$NOJQ"' EXIT
for b in bash cat grep sed dirname mktemp; do
  p=$(command -v "$b") && ln -s "$p" "$NOJQ/$b"
done
for h in block-destroy block-dangerous-rm warn-apply-without-plan block-secret-commit block-mcp-destroy suggest-validate; do
  PATH="$NOJQ" "$NOJQ/bash" "$HOOKS/$h.sh" <<<'{"tool_input":{"command":"ls","file_path":"x.tf"}}' >/dev/null 2>&1
  rc=$?
  got="OPEN(exit $rc)"; ((rc == 0)) && got=ALLOW; ((rc == 2)) && got=BLOCK
  record BLOCK "$got" "[no jq] $h" "H-1 fail closed"
done
for h in "${BASH_CHAIN[@]}"; do
  record BLOCK "$(run_chain 'this is not json' "$h")" "[invalid JSON] $h" "fail closed"
done

# --- report -------------------------------------------------------------------------------
printf '\n%-4s | %-6s | %-12s | %-74s | %s\n' "" "Expect" "Got" "Input" "Note"
printf '%s\n' "-----+--------+--------------+----------------------------------------------------------------------------+------------------------"
for r in "${ROWS[@]}"; do
  IFS=$'\x1f' read -r res exp got label note <<<"$r"
  printf '%-4s | %-6s | %-12s | %-74.74s | %s\n' "$res" "$exp" "$got" "$label" "$note"
done
printf '\n%d passed, %d failed (%d cases) - hooks: %s\n' "$PASS" "$FAIL" "$((PASS + FAIL))" "$HOOKS"
((FAIL == 0))
