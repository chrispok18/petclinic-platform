#!/usr/bin/env bash
# Hook: block-dangerous-rm.sh (PreToolUse on Bash)
# Purpose: Blocks 'rm -rf' on critical infrastructure directories.
# Why: Accidentally deleting terraform/, k8s/, or .github/ means
#      losing all infrastructure code. Git can recover it, but the blast radius
#      of an accidental 'rm -rf terraform/' is too high to leave unguarded.
# How: Checks if the command contains 'rm' with force/recursive flags targeting
#      protected directories. Exits 2 to deny execution.

set -Eeuo pipefail
HOOK_NAME="block-dangerous-rm"
fail_closed() { echo "BLOCKED by $HOOK_NAME: $1 - failing closed." >&2; exit 2; }
trap 'fail_closed "unexpected error at line $LINENO"' ERR

command -v jq >/dev/null 2>&1 || fail_closed "jq is not installed (sudo apt install jq), so the input cannot be inspected"
INPUT=$(cat)
COMMAND=$(jq -r '.tool_input.command // empty' <<<"$INPUT" 2>/dev/null) || fail_closed "tool input is not valid JSON"

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Protected directories — these contain all our infrastructure code
PROTECTED_DIRS="terraform k8s helm helm-values .github docs scripts .claude"

# Check for rm with force/recursive flags (-rf, -fr, -r -f, --recursive, etc.)
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*[rf][a-zA-Z]*\s+|--recursive|--force)'; then
  for dir in $PROTECTED_DIRS; do
    # Check if the rm command targets a protected directory
    # Match: rm -rf terraform, rm -rf ./terraform, rm -rf terraform/, etc.
    if echo "$COMMAND" | grep -qE "rm\s+.*(\s|/|^)\.?/?${dir}(/|\s|$)"; then
      echo "BLOCKED: Cannot 'rm -rf' the '${dir}/' directory." >&2
      echo "" >&2
      echo "This directory contains critical infrastructure code." >&2
      echo "If you need to remove specific files, delete them individually." >&2
      echo "If you need to reset the directory, use 'git checkout -- ${dir}/'." >&2
      exit 2
    fi
  done
fi

# Allow all other commands
exit 0
