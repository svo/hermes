#!/usr/bin/env bash

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${TESTS_DIR}/../../.." && pwd)"
FIXTURES="${REPO_ROOT}/.specs/005-hermes-check-correctness/fixtures"
HERMES_CHECK="${HERMES_CHECK:-${REPO_ROOT}/infrastructure/ansible/roles/openclaw/files/hermes-check}"

TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_CASE=""
CASE_FAILURES=0

TMP_ROOT="$(mktemp -d)"
BIN_DIR="${TMP_ROOT}/bin"
mkdir -p "$BIN_DIR"
cp "${TESTS_DIR}/stub-gog" "${BIN_DIR}/gog"
cp "${TESTS_DIR}/stub-fasttext" "${BIN_DIR}/fasttext"
chmod +x "${BIN_DIR}/gog" "${BIN_DIR}/fasttext"

MODEL_FILE_STUB="${TMP_ROOT}/urgency.bin"
: > "$MODEL_FILE_STUB"

cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

case_start() {
  CURRENT_CASE="$1"
  CASE_FAILURES=0
}

case_end() {
  if [ "$CASE_FAILURES" -eq 0 ]; then
    printf 'PASS %s\n' "$CURRENT_CASE"
    TESTS_PASSED=$((TESTS_PASSED + 1))
  else
    TESTS_FAILED=$((TESTS_FAILED + 1))
  fi
}

fail() {
  if [ "$CASE_FAILURES" -eq 0 ]; then
    printf 'FAIL %s\n' "$CURRENT_CASE" >&2
  fi
  CASE_FAILURES=$((CASE_FAILURES + 1))
  printf '     %s\n' "$1" >&2
}

assert_equals() {
  if [ "$2" != "$3" ]; then
    fail "$1"
    printf '       expected: %s\n' "$2" >&2
    printf '       actual:   %s\n' "$3" >&2
  fi
}

assert_contains() {
  case "$2" in
    *"$3"*) ;;
    *)
      fail "$1"
      printf '       expected to contain: %s\n' "$3" >&2
      ;;
  esac
}

assert_not_contains() {
  case "$2" in
    *"$3"*)
      fail "$1"
      printf '       expected NOT to contain: %s\n' "$3" >&2
      ;;
  esac
}

count_exact_lines() {
  printf '%s\n' "$1" | grep -cxF -- "$2" || true
}

count_matching_lines() {
  printf '%s\n' "$1" | grep -c -- "$2" || true
}

field() {
  printf '%s\n' "$RUN_OUT" | sed -n "s/^$1: //p" | head -1
}

listed_lines() {
  printf '%s\n' "$RUN_OUT" | grep '^  - ' || true
}

run_check() {
  local vip="" home_dir="" argv_log=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --vip) vip="$2"; shift 2 ;;
      --home) home_dir="$2"; shift 2 ;;
      --argv-log) argv_log="$2"; shift 2 ;;
      *) break ;;
    esac
  done

  local gmail="$1" calendar="$2"
  shift 2
  local run_dir errexit_was_set=""
  run_dir="$(mktemp -d "${TMP_ROOT}/run.XXXXXX")"
  if [ -z "$home_dir" ]; then
    home_dir="${run_dir}/home"
  fi
  mkdir -p "$home_dir"

  if [ -n "$vip" ]; then
    mkdir -p "${home_dir}/.openclaw/hermes-check"
    printf '%s\n' "$vip" > "${home_dir}/.openclaw/hermes-check/vip-senders.txt"
  fi

  if [ -f "${FIXTURES}/${gmail}" ]; then
    gmail="${FIXTURES}/${gmail}"
  fi
  if [ -f "${FIXTURES}/${calendar}" ]; then
    calendar="${FIXTURES}/${calendar}"
  fi

  case $- in *e*) errexit_was_set="yes" ;; esac
  set +e
  env -i \
    HOME="$home_dir" \
    PATH="${BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    TZ=UTC \
    HERMES_MODEL_FILE="$MODEL_FILE_STUB" \
    GOG_FIXTURE_GMAIL="$gmail" \
    GOG_FIXTURE_CALENDAR="$calendar" \
    ${argv_log:+GOG_ARGV_LOG="$argv_log"} \
    "$@" \
    bash "$HERMES_CHECK" >"${run_dir}/stdout" 2>"${run_dir}/stderr"
  # shellcheck disable=SC2034
  RUN_STATUS=$?
  [ -n "$errexit_was_set" ] && set -e

  # shellcheck disable=SC2034
  RUN_OUT="$(cat "${run_dir}/stdout")"
  # shellcheck disable=SC2034
  RUN_ERR="$(cat "${run_dir}/stderr")"
}

new_home() {
  local dir
  dir="$(mktemp -d "${TMP_ROOT}/home.XXXXXX")"
  printf '%s' "$dir"
}

new_log() {
  local file
  file="$(mktemp "${TMP_ROOT}/argv.XXXXXX")"
  printf '%s' "$file"
}

assert_universal_invariants() {
  local new urgent vip other
  assert_equals "exit status is zero" "0" "$RUN_STATUS"
  assert_equals "exactly one SUMMARY section" "1" \
    "$(count_exact_lines "$RUN_OUT" '--- SUMMARY ---')"
  assert_equals "exactly one ACTION_NEEDED line" "1" \
    "$(count_matching_lines "$RUN_OUT" '^ACTION_NEEDED: ')"

  new="$(field NEW_UNREAD)"
  urgent="$(field URGENT)"
  vip="$(field VIP)"
  other="$(field OTHER)"
  assert_equals "NEW_UNREAD reported" "1" "$(count_matching_lines "$RUN_OUT" '^NEW_UNREAD: ')"
  if [ -n "$new" ] && [ -n "$urgent" ] && [ -n "$vip" ] && [ -n "$other" ]; then
    assert_equals "URGENT + VIP + OTHER == NEW_UNREAD" \
      "$new" "$((urgent + vip + other))"
    if [ "$other" -lt 0 ]; then
      fail "OTHER is negative: $other"
    fi
  fi

  assert_not_contains "no integer-expression errors" "$RUN_ERR" "integer expression expected"
  assert_not_contains "no misplaced continue" "$RUN_ERR" "continue: only meaningful"
}

report_totals() {
  printf '\n%s: %d passed, %d failed\n' "$1" "$TESTS_PASSED" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
