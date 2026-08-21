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

test_replaces_single_token
test_replaces_multiple_tokens_on_one_line
test_normalizes_dotted_and_dashed_variable_names
test_missing_variable_warns_and_empties_token
test_empty_variable_warns_and_empties_token
test_processes_multiple_matched_files
test_preserves_missing_trailing_newline
test_excludes_dot_terraform_directory
test_leaves_files_without_tokens_unchanged
test_no_files_matched_warns_but_succeeds
test_no_arguments_is_an_error

echo
echo "$pass passed, $fail failed"
[ "$fail" -eq 0 ]
