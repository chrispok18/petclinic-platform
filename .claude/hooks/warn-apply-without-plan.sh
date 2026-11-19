#!/usr/bin/env bash
# Hook: warn-apply-without-plan.sh (PreToolUse on Bash)
# Purpose: Every 'terraform apply' run by Claude needs explicit human confirmation.
# Why: exit 1 only shows a warning and lets the command run, so the old version never asked.
#      Claude Code asks the user when a PreToolUse hook returns permissionDecision "ask".
# How: parses the command with lib/command-parse.sh (flag tolerant: terraform -chdir=... apply).
#      On any apply it prints the "ask" JSON on stdout and exits 0. The reason text says whether a
#      saved plan file was given (safe workflow) or not (re-plans at apply time, maybe -auto-approve).
#      'apply -destroy' is hard-blocked by block-destroy.sh.
#      Fails CLOSED (exit 2) if jq is missing, the input is unreadable, or anything errors.

set -Eeuo pipefail
HOOK_NAME="warn-apply-without-plan"
fail_closed() { echo "BLOCKED by $HOOK_NAME: $1 - failing closed." >&2; exit 2; }
trap 'fail_closed "unexpected error at line $LINENO"' ERR

command -v jq >/dev/null 2>&1 || fail_closed "jq is not installed (sudo apt install jq), so the command cannot be inspected"
INPUT=$(cat)
COMMAND=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null) || fail_closed "tool input is not valid JSON"
[[ -n $COMMAND ]] || exit 0

HOOK_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/command-parse.sh
source "$HOOK_DIR/lib/command-parse.sh" || fail_closed "cannot load $HOOK_DIR/lib/command-parse.sh"

APPLY_BIN="" APPLY_PLAN="" APPLY_AUTO=0

tf_apply_cb() {
  local bin=${1##*/}
  shift
  if [[ ! $bin =~ ^(terraform|terragrunt|tofu)$ ]]; then return 1; fi
  local sub="" t skip=0
  APPLY_PLAN="" APPLY_AUTO=0
  while (($#)); do
    t=$1
    shift
    if [[ -z $sub ]]; then
      if [[ $t != -* ]]; then sub=$t; fi
      continue
    fi
    if ((skip)); then skip=0; continue; fi
    case $t in
      -auto-approve | --auto-approve | -auto-approve=true) APPLY_AUTO=1 ;;
      -var | -var-file | -target | -replace | -parallelism | -state | -state-out | -backup | -lock-timeout) skip=1 ;;
      -*) ;;
      *) APPLY_PLAN=$t ;; # positional argument = saved plan file
    esac
  done
  if [[ $sub != apply ]]; then return 1; fi
  APPLY_BIN=$bin
  return 0
}

if hp_any "$COMMAND" tf_apply_cb; then
  if [[ -n $APPLY_PLAN ]]; then
    REASON="'$APPLY_BIN apply $APPLY_PLAN' changes real AWS resources. A saved plan is the safe workflow: confirm only if you reviewed that plan (and it is not a destroy plan)."
  elif ((APPLY_AUTO)); then
    REASON="'$APPLY_BIN apply -auto-approve' WITHOUT a saved plan: Terraform re-plans and applies with no prompt. Recommended: terraform plan -out plan.out, review, terraform apply plan.out."
  else
    REASON="'$APPLY_BIN apply' WITHOUT a saved plan: the changes may differ from what you reviewed. Recommended: terraform plan -out plan.out, review, terraform apply plan.out."
  fi
  jq -n --arg r "$REASON" \
    '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}'
  exit 0
fi

exit 0
