#!/usr/bin/env bash
# Pure-bash drop-in replacement for qetza.replacetokens-task@6 with default settings.
# No perl/sed/awk dependency for the token substitution itself.
#
# Defaults replicated:
#   - token pattern: #{ }#
#   - variable source: environment variables (as set by the preceding
#     AzureKeyVault@N task running with RunAsPreJob: true)
#   - variable name -> env var mapping: uppercase, non-alphanumeric -> "_".
#     A token's name is normalized this way to build its lookup key, and the
#     raw process environment is read directly (via `env -0`, not bash's own
#     ${!key} variable table) and normalized the same way -- because bash
#     silently refuses to import an env var into its variable table if the
#     literal name isn't a valid shell identifier (e.g. one containing a
#     hyphen), even though the value is genuinely present in the process
#     environment and visible to tools like printenv. This makes lookup work
#     regardless of whether Azure DevOps happened to keep the raw character
#     (e.g. a hyphen) or convert it when it exposed the variable.
#   - actionOnMissing: warn (does not fail the step)
#   - keepToken: false (missing/empty variable is replaced with an empty string)
#
# IMPORTANT (confirmed on a live Azure Pipelines run): Azure Pipelines only
# auto-exposes NON-secret pipeline variables as environment variables to
# plain script/bash steps. Secret variables -- which is exactly what
# AzureKeyVault@N produces -- are NOT auto-exposed, regardless of naming.
# You must explicitly map each one in the calling step's YAML, e.g.:
#   - bash: ./replace-tokens.sh '**/*.tf'
#     env:
#       APIKEY: $(ApiKey)
#       MY_CONNECTION_STRING: $(My.Connection-String)
# (the env: key must equal this script's normalize_key() output for that
# token name: uppercase, non-alphanumeric -> "_"). The companion
# replace-tokens.yml step template automates this via its `secretVariables`
# parameter -- use that instead of this standalone script if you can.
#
# Logging (values are never printed, only token/variable names):
#   - a token that gets replaced with a non-empty value -> info line
#   - a token whose variable exists but is set to an empty string -> warning
#   - a token whose variable doesn't exist at all -> warning
#
# Note: matching is done line-by-line, so a token split across a line break
# will not be recognized (the original task scans the whole file; this is
# the one behavioral difference of going dependency-free).
#
# Usage:
#   replace-tokens.sh '<glob-pattern-1>' ['<glob-pattern-2>' ...]
#
# Example:
#   replace-tokens.sh '**/*.tf'

set -euo pipefail
shopt -s globstar nullglob dotglob

# ANSI styling: dim the routine "processing" lines, bold+green the
# "replaced" lines so actual substitutions stand out in the log. Both the
# Azure Pipelines log viewer and ordinary terminals render these; set
# NO_COLOR to disable.
if [ -z "${NO_COLOR:-}" ]; then
  c_dim=$'\033[2m'
  c_bold_green=$'\033[1;32m'
  c_reset=$'\033[0m'
else
  c_dim=''
  c_bold_green=''
  c_reset=''
fi

# Directories to skip entirely (e.g. Terraform provider/module cache).
exclude_dirs=(.terraform)

is_excluded() {
  local path="$1" dir
  for dir in "${exclude_dirs[@]}"; do
    case "/$path/" in
      *"/$dir/"*) return 0 ;;
    esac
  done
  return 1
}

if [ "$#" -eq 0 ]; then
  echo "##vso[task.logissue type=error]replace-tokens.sh: no target file pattern(s) supplied."
  exit 1
fi

files=()
for pattern in "$@"; do
  for f in $pattern; do
    [ -f "$f" ] || continue
    is_excluded "$f" && continue
    files+=("$f")
  done
done

if [ "${#files[@]}" -eq 0 ]; then
  # Blank/whitespace-only patterns (e.g. an empty targetFiles) mean "nothing
  # to do" -- a normal, expected case, not a warning. Only warn when a
  # non-blank pattern was actually supplied and genuinely matched nothing.
  all_blank=1
  for pattern in "$@"; do
    if [ -n "${pattern//[[:space:]]/}" ]; then
      all_blank=0
      break
    fi
  done
  if [ "$all_blank" -eq 1 ]; then
    echo "${c_dim}replace-tokens.sh: no target file pattern(s) supplied, skipping${c_reset}"
  else
    echo "##vso[task.logissue type=warning]replace-tokens.sh: no files matched pattern(s): $*"
  fi
  exit 0
fi

# Normalizes a token/variable name to a lookup key: uppercase, any non
# [A-Za-z0-9] character becomes "_".
normalize_key() {
  local name="$1" key
  key=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
  key="${key//[^A-Za-z0-9]/_}"
  printf '%s' "$key"
}

# Build a normalized-key -> value lookup from the raw process environment
# instead of relying on bash's own variable table (${!key}): bash silently
# refuses to import env vars whose literal name isn't a valid shell
# identifier (e.g. one containing a hyphen), even though the value is still
# present in the process environment and visible to tools like printenv.
# Reading it back via `env -0` sees it regardless of the raw name's shape.
declare -A env_values
while IFS= read -r -d '' entry; do
  name="${entry%%=*}"
  value="${entry#*=}"
  env_values["$(normalize_key "$name")"]="$value"
done < <(env -0)

# Replaces every #{...}# token on one line. Emits REPLACED:/EMPTYVALUE:/MISSING:
# events (name only, never the value) on fd 3 for the caller to log.
process_line() {
  local line="$1" out="" before rest name after key value
  while [[ "$line" == *'#{'*'}#'* ]]; do
    before="${line%%#{*}"
    rest="${line#*#{}"
    name="${rest%%\}#*}"
    after="${rest#*\}#}"
    key=$(normalize_key "$name")
    if [ -n "${env_values[$key]+x}" ]; then
      value="${env_values[$key]}"
      if [ -n "$value" ]; then
        out+="${before}${value}"
        printf 'REPLACED:%s\n' "$name" >&3
      else
        out+="${before}"
        printf 'EMPTYVALUE:%s\n' "$name" >&3
      fi
    else
      out+="${before}"
      printf 'MISSING:%s\n' "$name" >&3
    fi
    line="$after"
  done
  out+="$line"
  printf '%s\n' "$out"
}

log_event() {
  local event="$1" file="$2" name="${1#*:}"
  case "$event" in
    REPLACED:*)
      echo "${c_bold_green}replace-tokens: replaced #{$name}# in $file${c_reset}"
      ;;
    EMPTYVALUE:*)
      echo "##vso[task.logissue type=warning]replace-tokens: variable for token '#{$name}#' exists but has no value (empty) in $file"
      ;;
    MISSING:*)
      echo "##vso[task.logissue type=warning]replace-tokens: variable not found for token '#{$name}#' in $file"
      ;;
  esac
}

exit_code=0

for file in "${files[@]}"; do
  echo "${c_dim}replace-tokens: processing $file${c_reset}"

  tmpfile=$(mktemp)
  eventfile=$(mktemp)

  # Preserve "no trailing newline" files faithfully: read handles the last
  # partial line via the `|| [ -n "$line" ]` guard, but process_line always
  # emits a newline after it -- so if the source file didn't end in one,
  # trim the newline that was just added back off below.
  had_trailing_newline=1
  [ -s "$file" ] && [ -n "$(tail -c1 "$file")" ] && had_trailing_newline=0

  {
    while IFS= read -r line || [ -n "$line" ]; do
      process_line "$line"
    done < "$file"
  } 3>"$eventfile" > "$tmpfile"

  [ "$had_trailing_newline" -eq 0 ] && truncate -s -1 "$tmpfile"

  mv "$tmpfile" "$file"

  while IFS= read -r event; do
    [ -z "$event" ] && continue
    log_event "$event" "$file"
  done < "$eventfile"
  rm -f "$eventfile"
done

exit "$exit_code"
