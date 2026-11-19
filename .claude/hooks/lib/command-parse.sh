#!/usr/bin/env bash
# Shared command parser for the PreToolUse Bash hooks (sourced, not executed).
#
# Why: plain regexes on the raw command missed flag variants such as
#   terraform -chdir=terraform/environments/dev destroy
#   kubectl -n petclinic-dev delete secret rds-credentials
# and produced false positives on text that merely mentions a command (grep, echo, commit messages).
#
# How: split the command line into simple commands (; && || | & newline, plus the inside of $( ),
# backticks and subshells), tokenize each one, skip env assignments and wrapper programs
# (sudo, env, timeout, nohup, xargs, ...), descend into `bash -c "..."` / `eval ...`, and hand the
# real program + its arguments to a check function ("callback").
#
# This is a heuristic, not a shell parser: it errs on the side of blocking. Indirection such as
# T=terraform; $T destroy is not resolved (permissions.deny in settings.json is a second layer).
#
# Callers use these functions only inside `if` conditions (they return 1 for "no match").

# Strip shell quoting/grouping characters from the ends of a token.
hp_clean_token() {
  local t=$1
  while [[ $t =~ ^[\"\'\(\$\`\{] ]]; do t=${t:1}; done
  while [[ $t =~ [\"\'\)\`\}\;]$ ]]; do t=${t%?}; done
  printf '%s' "$t"
}

# hp_check_command <command-string> <callback> [depth]
# Returns 0 if <callback> matched the real program of this simple command.
hp_check_command() {
  local cmd=$1 cb=$2 depth=${3:-0}
  if ((depth > 3)); then return 1; fi

  local raw=() toks=() t
  read -ra raw <<<"$cmd" || true
  for t in "${raw[@]}"; do
    t=$(hp_clean_token "$t")
    if [[ -n $t ]]; then toks+=("$t"); fi
  done

  local n=${#toks[@]} i=0 j base
  while ((i < n)); do
    t=${toks[i]}
    # VAR=value prefixes
    if [[ $t =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; then i=$((i + 1)); continue; fi
    base=${t##*/}
    case $base in
      sudo | doas)
        i=$((i + 1))
        while ((i < n)) && [[ ${toks[i]} == -* ]]; do
          if [[ ${toks[i]} =~ ^-(u|g|C|D|h|p|r|t|U)$ ]]; then i=$((i + 1)); fi
          i=$((i + 1))
        done
        continue
        ;;
      env)
        i=$((i + 1))
        while ((i < n)) && [[ ${toks[i]} == -* || ${toks[i]} =~ ^[A-Za-z_][A-Za-z0-9_]*= ]]; do
          if [[ ${toks[i]} =~ ^-(u|C|S)$ ]]; then i=$((i + 1)); fi
          i=$((i + 1))
        done
        continue
        ;;
      command | exec | nohup | time | builtin | stdbuf | xargs | nice | ionice | chronic | watch)
        i=$((i + 1))
        while ((i < n)) && [[ ${toks[i]} == -* ]]; do
          if [[ ${toks[i]} =~ ^-(n|c|I|L|P|s|d|E)$ ]]; then i=$((i + 1)); fi
          i=$((i + 1))
        done
        continue
        ;;
      timeout)
        i=$((i + 1))
        while ((i < n)) && [[ ${toks[i]} == -* ]]; do
          if [[ ${toks[i]} =~ ^-(s|k)$ ]]; then i=$((i + 1)); fi
          i=$((i + 1))
        done
        i=$((i + 1)) # the duration
        continue
        ;;
      eval)
        hp_check_command "${toks[*]:i+1}" "$cb" $((depth + 1))
        return
        ;;
      bash | sh | zsh | dash | ksh)
        j=$((i + 1))
        while ((j < n)); do
          if [[ ${toks[j]} == -*c* && ${toks[j]} != --* ]]; then
            hp_check_command "${toks[*]:j+1}" "$cb" $((depth + 1))
            return
          fi
          j=$((j + 1))
        done
        return 1
        ;;
    esac
    break
  done

  if ((i >= n)); then return 1; fi
  "$cb" "${toks[@]:i}"
}

# hp_any <full-command-line> <callback>
# Returns 0 if <callback> matched any simple command in the line.
hp_any() {
  local line=$1 cb=$2 seg rest
  local segs=() pieces=()
  mapfile -t segs < <(printf '%s\n' "$line" | sed -E 's/(\|\||&&|;|\||&)/\n/g')
  for seg in "${segs[@]}"; do
    pieces+=("$seg")
    # Command substitution / subshell bodies start a new command position.
    rest=$seg
    while [[ $rest == *'('* ]]; do rest=${rest#*\(}; pieces+=("$rest"); done
    rest=$seg
    while [[ $rest == *'`'* ]]; do rest=${rest#*\`}; pieces+=("$rest"); done
  done
  for seg in "${pieces[@]}"; do
    if hp_check_command "$seg" "$cb"; then return 0; fi
  done
  return 1
}
