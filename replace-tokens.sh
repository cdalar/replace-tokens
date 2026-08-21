#!/usr/bin/env bash
# Pure-bash drop-in replacement for qetza.replacetokens-task@6 with default settings.
# No perl/sed/awk dependency for the token substitution itself.
#
# Defaults replicated:
#   - token pattern: #{ }#
#   - variable source: environment variables (as set by the preceding
#     AzureKeyVault@N task running with RunAsPreJob: true)
#   - variable name -> env var mapping: uppercase, non-alphanumeric -> "_"
#     (this is how Azure DevOps exposes pipeline/KeyVault variables as env vars)
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
  echo "##vso[task.logissue type=warning]replace-tokens.sh: no files matched pattern(s): $*"
  exit 0
fi

# Normalizes a token name to the env var name ADO would expose it as:
# uppercase, any non [A-Za-z0-9] character becomes "_".
normalize_key() {
  local name="$1" key
  key=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')
  key="${key//[^A-Za-z0-9]/_}"
  printf '%s' "$key"
}

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
    if [ -n "${!key+x}" ]; then
      value="${!key}"
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
      echo "replace-tokens: replaced #{$name}# in $file"
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
  echo "replace-tokens: processing $file"

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
