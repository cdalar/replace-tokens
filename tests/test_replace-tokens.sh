#!/usr/bin/env bash
# Test suite for replace-tokens.sh: env var lookup + #{ }# token replacement.
# Pure bash, no external test framework -- run directly:
#   ./tests/test_replace-tokens.sh

set -uo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/replace-tokens.sh"

pass=0
fail=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $desc"
    echo "  expected: $expected"
    echo "  actual:   $actual"
  fi
}

assert_contains() {
  local desc="$1" haystack="$2" needle="$3"
  if [[ "$haystack" == *"$needle"* ]]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $desc"
    echo "  expected to contain: $needle"
    echo "  actual: $haystack"
  fi
}

assert_status() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" -eq "$actual" ]; then
    pass=$((pass + 1))
  else
    fail=$((fail + 1))
    echo "FAIL: $desc (exit code expected $expected, got $actual)"
  fi
}

test_replaces_single_token() {
  local dir out status
  dir=$(mktemp -d)
  printf 'url = #{ApiUrl}#\n' >"$dir/file.txt"

  out=$(cd "$dir" && env -i PATH="$PATH" APIURL="https://example.com" bash "$SCRIPT" 'file.txt' 2>&1)
  status=$?

  assert_status "single token: exit code" 0 "$status"
  assert_eq "single token: file content" 'url = https://example.com' "$(cat "$dir/file.txt")"
  assert_contains "single token: log line" "$out" "replaced #{ApiUrl}#"

  rm -rf "$dir"
}

test_replaces_multiple_tokens_on_one_line() {
  local dir out status
  dir=$(mktemp -d)
  printf '#{A}#-#{B}#\n' >"$dir/file.txt"

  out=$(cd "$dir" && env -i PATH="$PATH" A="foo" B="bar" bash "$SCRIPT" 'file.txt' 2>&1)
  status=$?

  assert_status "multi token: exit code" 0 "$status"
  assert_eq "multi token: file content" 'foo-bar' "$(cat "$dir/file.txt")"

  rm -rf "$dir"
}

test_normalizes_dotted_and_dashed_variable_names() {
  local dir out status
  dir=$(mktemp -d)
  printf 'conn=#{My.Connection-String}#\n' >"$dir/file.txt"

  out=$(cd "$dir" && env -i PATH="$PATH" MY_CONNECTION_STRING="xyz" bash "$SCRIPT" 'file.txt' 2>&1)
  status=$?

  assert_status "normalized name: exit code" 0 "$status"
  assert_eq "normalized name: file content" 'conn=xyz' "$(cat "$dir/file.txt")"

  rm -rf "$dir"
}

test_finds_variable_whose_raw_env_name_has_a_hyphen() {
  local dir out status
  dir=$(mktemp -d)
  printf 'val=#{HASHICORP-AZURERM}#\n' >"$dir/file.txt"

  # The raw env var name here keeps the literal hyphen (as opposed to a
  # bash `VAR=val` assignment, which would reject that as an identifier).
  # bash never imports such a name into its own ${!key} variable table, so
  # this only passes if lookups go through the env -0 dump instead.
  out=$(cd "$dir" && env -i PATH="$PATH" 'HASHICORP-AZURERM=secretvalue' bash "$SCRIPT" 'file.txt' 2>&1)
  status=$?

  assert_status "hyphenated raw name: exit code" 0 "$status"
  assert_eq "hyphenated raw name: file content" 'val=secretvalue' "$(cat "$dir/file.txt")"
  assert_contains "hyphenated raw name: log line" "$out" "replaced #{HASHICORP-AZURERM}#"

  rm -rf "$dir"
}

test_missing_variable_warns_and_empties_token() {
  local dir out status
  dir=$(mktemp -d)
  printf 'val=#{Missing.Var}#\n' >"$dir/file.txt"

  out=$(cd "$dir" && env -i PATH="$PATH" bash "$SCRIPT" 'file.txt' 2>&1)
  status=$?

  assert_status "missing var: exit code" 0 "$status"
  assert_eq "missing var: file content" 'val=' "$(cat "$dir/file.txt")"
  assert_contains "missing var: warning" "$out" "##vso[task.logissue type=warning]"
  assert_contains "missing var: mentions token" "$out" "Missing.Var"
  assert_contains "missing var: says not found" "$out" "not found"

  rm -rf "$dir"
}

test_empty_variable_warns_and_empties_token() {
  local dir out status
  dir=$(mktemp -d)
  printf 'val=#{Empty.Var}#\n' >"$dir/file.txt"

  out=$(cd "$dir" && env -i PATH="$PATH" EMPTY_VAR="" bash "$SCRIPT" 'file.txt' 2>&1)
  status=$?

  assert_status "empty var: exit code" 0 "$status"
  assert_eq "empty var: file content" 'val=' "$(cat "$dir/file.txt")"
  assert_contains "empty var: warning" "$out" "##vso[task.logissue type=warning]"
  assert_contains "empty var: says no value" "$out" "no value (empty)"

  rm -rf "$dir"
}

test_processes_multiple_matched_files() {
  local dir out status
  dir=$(mktemp -d)
  printf 'a=#{X}#\n' >"$dir/a.txt"
  printf 'b=#{X}#\n' >"$dir/b.txt"

  out=$(cd "$dir" && env -i PATH="$PATH" X="1" bash "$SCRIPT" '*.txt' 2>&1)
  status=$?

  assert_status "multi file: exit code" 0 "$status"
  assert_eq "multi file: a.txt content" 'a=1' "$(cat "$dir/a.txt")"
  assert_eq "multi file: b.txt content" 'b=1' "$(cat "$dir/b.txt")"
  assert_contains "multi file: logs a.txt" "$out" "processing a.txt"
  assert_contains "multi file: logs b.txt" "$out" "processing b.txt"

  rm -rf "$dir"
}

test_preserves_missing_trailing_newline() {
  local dir status last_byte
  dir=$(mktemp -d)
  printf 'no newline #{X}#' >"$dir/file.txt"

  (cd "$dir" && env -i PATH="$PATH" X="value" bash "$SCRIPT" 'file.txt' >/dev/null 2>&1)
  status=$?
  last_byte=$(tail -c1 "$dir/file.txt")

  assert_status "no trailing newline: exit code" 0 "$status"
  assert_eq "no trailing newline: content" 'no newline value' "$(cat "$dir/file.txt")"
  assert_eq "no trailing newline: last byte is not a newline" 'e' "$last_byte"

  rm -rf "$dir"
}

test_excludes_dot_terraform_directory() {
  local dir out status
  dir=$(mktemp -d)
  mkdir -p "$dir/.terraform"
  printf 'val=#{X}#\n' >"$dir/.terraform/skip.tf"
  printf 'val=#{X}#\n' >"$dir/keep.tf"

  out=$(cd "$dir" && env -i PATH="$PATH" X="value" bash "$SCRIPT" '**/*.tf' 2>&1)
  status=$?

  assert_status "excluded dir: exit code" 0 "$status"
  assert_eq "excluded dir: keep.tf replaced" 'val=value' "$(cat "$dir/keep.tf")"
  assert_eq "excluded dir: skip.tf untouched" 'val=#{X}#' "$(cat "$dir/.terraform/skip.tf")"

  rm -rf "$dir"
}

test_leaves_files_without_tokens_unchanged() {
  local dir status
  dir=$(mktemp -d)
  printf 'nothing to see here\n' >"$dir/file.txt"

  (cd "$dir" && env -i PATH="$PATH" bash "$SCRIPT" 'file.txt' >/dev/null 2>&1)
  status=$?

  assert_status "no tokens: exit code" 0 "$status"
  assert_eq "no tokens: content unchanged" 'nothing to see here' "$(cat "$dir/file.txt")"

  rm -rf "$dir"
}

test_no_files_matched_warns_but_succeeds() {
  local dir out status
  dir=$(mktemp -d)

  out=$(cd "$dir" && env -i PATH="$PATH" bash "$SCRIPT" 'nomatch/*.txt' 2>&1)
  status=$?

  assert_status "no match: exit code" 0 "$status"
  assert_contains "no match: warning" "$out" "##vso[task.logissue type=warning]"
  assert_contains "no match: mentions pattern" "$out" "no files matched pattern(s)"

  rm -rf "$dir"
}

test_no_arguments_is_an_error() {
  local out status
  out=$(env -i PATH="$PATH" bash "$SCRIPT" 2>&1)
  status=$?

  assert_status "no args: exit code" 1 "$status"
  assert_contains "no args: error" "$out" "##vso[task.logissue type=error]"
  assert_contains "no args: mentions missing patterns" "$out" "no target file pattern(s) supplied"
}

# name:description pairs, run in order with a one-line explanation printed
# before each one executes.
cases=(
  "test_replaces_single_token:Replaces a single #{Token}# with its env var value and logs the replacement"
  "test_replaces_multiple_tokens_on_one_line:Replaces multiple tokens on the same line"
  "test_normalizes_dotted_and_dashed_variable_names:Normalizes dotted/dashed variable names (My.Connection-String -> MY_CONNECTION_STRING) before lookup"
  "test_finds_variable_whose_raw_env_name_has_a_hyphen:Finds a variable even when its raw env var name literally contains a hyphen (bash can't see it via \${!key})"
  "test_missing_variable_warns_and_empties_token:Missing variable -> token emptied, warning logged, exit 0"
  "test_empty_variable_warns_and_empties_token:Present-but-empty variable -> token emptied, \"no value\" warning logged"
  "test_processes_multiple_matched_files:Processes every file matched by a glob pattern, not just the first"
  "test_preserves_missing_trailing_newline:Preserves a file's lack of trailing newline after processing"
  "test_excludes_dot_terraform_directory:Skips files inside .terraform/"
  "test_leaves_files_without_tokens_unchanged:Leaves files with no tokens byte-for-byte unchanged"
  "test_no_files_matched_warns_but_succeeds:No files match the pattern -> warning logged, exit 0 (not a failure)"
  "test_no_arguments_is_an_error:No pattern argument at all -> error logged, exit 1"
)

for case in "${cases[@]}"; do
  name="${case%%:*}"
  desc="${case#*:}"
  echo "- $desc"
  "$name"
done

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
