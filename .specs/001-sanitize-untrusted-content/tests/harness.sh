#!/usr/bin/env bash
#
# Shared assertions and the hermetic runner for 001's checks. Sourced, not run.
#
# Assertion style follows the plan: one behaviour per case, named
# should_<behaviour>_when_<condition>.

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${TESTS_DIR}/../../.." && pwd)"
FIXTURES="${REPO_ROOT}/.specs/005-hermes-check-correctness/fixtures"
# Overridable so a case can be pointed at another copy of the script — which
# is how these were shown to fail before the sanitizer landed.
HERMES_CHECK="${HERMES_CHECK:-${REPO_ROOT}/infrastructure/ansible/roles/openclaw/files/hermes-check}"
ENTRYPOINT="${ENTRYPOINT:-${REPO_ROOT}/infrastructure/ansible/roles/openclaw/files/entrypoint.sh}"

TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_CASE=""

TMP_ROOT="$(mktemp -d)"
BIN_DIR="${TMP_ROOT}/bin"
mkdir -p "$BIN_DIR"
cp "${TESTS_DIR}/stub-gog" "${BIN_DIR}/gog"
cp "${TESTS_DIR}/stub-fasttext" "${BIN_DIR}/fasttext"
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
  # assert_equals <what> <expected> <actual>
  if [ "$2" != "$3" ]; then
    fail "$1"
    printf '       expected: %s\n' "$2" >&2
    printf '       actual:   %s\n' "$3" >&2
  fi
}

assert_contains() {
  # assert_contains <what> <haystack> <needle>
  case "$2" in
    *"$3"*) ;;
    *)
      fail "$1"
      printf '       expected to contain: %s\n' "$3" >&2
      ;;
  esac
}

assert_not_contains() {
  # assert_not_contains <what> <haystack> <needle>
  case "$2" in
    *"$3"*)
      fail "$1"
      printf '       expected NOT to contain: %s\n' "$3" >&2
      ;;
  esac
}

# Number of lines in $1 that are exactly $2.
count_exact_lines() {
  printf '%s\n' "$1" | grep -cxF -- "$2" || true
}

# Number of lines in $1 matching the basic regex $2.
count_matching_lines() {
  printf '%s\n' "$1" | grep -c -- "$2" || true
}

# 1-based line number of the first line in $1 that is exactly $2, or empty.
line_number_of() {
  printf '%s\n' "$1" | grep -nxF -- "$2" | head -1 | cut -d: -f1
}

# Run hermes-check against two fixtures in a clean environment: empty env, a
# private HOME so the seen-message state never carries between cases, UTC so
# rendered times are stable, and the stubs ahead of anything real on PATH.
#
#   run_check <gmail-fixture> <calendar-fixture> [VAR=VALUE ...]
#
# Sets RUN_OUT, RUN_ERR, RUN_STATUS.
run_check() {
  local gmail="$1" calendar="$2"
  shift 2
  local run_dir errexit_was_set=""
  run_dir="$(mktemp -d "${TMP_ROOT}/run.XXXXXX")"
  mkdir -p "${run_dir}/home"

  # Restore errexit to whatever the caller had rather than forcing it on: an
  # unconditional `set -e` here would make the next assignment whose command
  # substitution finds nothing kill the whole suite silently.
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

  # RUN_* are the contract with the suites that source this file; shellcheck
  # cannot see those consumers from here.
  # shellcheck disable=SC2034
  RUN_OUT="$(cat "${run_dir}/stdout")"
  # shellcheck disable=SC2034
  RUN_ERR="$(cat "${run_dir}/stderr")"
}

# The subject as emitted on the single email line of the last run.
emitted_subject() {
  printf '%s\n' "$RUN_OUT" | sed -n 's/^  - \(\[[A-Z]*\] \)\{0,1\}From: [^|]*| Subject: //p'
}

# The sender as emitted on the single email line of the last run.
emitted_sender() {
  printf '%s\n' "$RUN_OUT" | sed -n 's/^  - \(\[[A-Z]*\] \)\{0,1\}From: \(.*\) | Subject: .*$/\2/p'
}

report_totals() {
  printf '\n%s: %d passed, %d failed\n' "$1" "$TESTS_PASSED" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
