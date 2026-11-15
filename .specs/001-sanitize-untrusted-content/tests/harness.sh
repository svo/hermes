#!/usr/bin/env bash

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${TESTS_DIR}/../../.." && pwd)"
FIXTURES="${REPO_ROOT}/.specs/005-hermes-check-correctness/fixtures"
HERMES_CHECK="${HERMES_CHECK:-${REPO_ROOT}/infrastructure/ansible/roles/openclaw/files/hermes-check}"
ENTRYPOINT="${ENTRYPOINT:-${REPO_ROOT}/infrastructure/ansible/roles/openclaw/files/entrypoint.sh}"

TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_CASE=""

TMP_ROOT="$(mktemp -d)"
BIN_DIR="${TMP_ROOT}/bin"
mkdir -p "$BIN_DIR"
STUBS="${REPO_ROOT}/.specs/005-hermes-check-correctness/tests"
cp "${STUBS}/stub-gog" "${BIN_DIR}/gog"
cp "${STUBS}/stub-fasttext" "${BIN_DIR}/fasttext"
chmod +x "${BIN_DIR}/gog" "${BIN_DIR}/fasttext"

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

line_number_of() {
  printf '%s\n' "$1" | grep -nxF -- "$2" | head -1 | cut -d: -f1
}

run_check() {
  local gmail="$1" calendar="$2"
  shift 2
  local run_dir errexit_was_set=""
  run_dir="$(mktemp -d "${TMP_ROOT}/run.XXXXXX")"
  mkdir -p "${run_dir}/home"

  case $- in *e*) errexit_was_set="yes" ;; esac
  set +e
  env -i \
    HOME="${run_dir}/home" \
    PATH="${BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    TZ=UTC \
    GOG_FIXTURE_GMAIL="${FIXTURES}/${gmail}" \
    GOG_FIXTURE_CALENDAR="${FIXTURES}/${calendar}" \
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

emitted_subject() {
  printf '%s\n' "$RUN_OUT" | sed -n 's/^  - \(\[[A-Z]*\] \)\{0,1\}From: [^|]*| Subject: //p'
}

emitted_sender() {
  printf '%s\n' "$RUN_OUT" | sed -n 's/^  - \(\[[A-Z]*\] \)\{0,1\}From: \(.*\) | Subject: .*$/\2/p'
}

report_totals() {
  printf '\n%s: %d passed, %d failed\n' "$1" "$TESTS_PASSED" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
