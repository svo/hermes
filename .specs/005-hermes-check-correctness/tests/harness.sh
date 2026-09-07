#!/usr/bin/env bash
#
# Shared assertions and the hermetic runner for 005's checks. Sourced, not run.
#
# Assertion style follows the plan: one behaviour per case, named
# should_<behaviour>_when_<condition>.
#
# This is the harness `bin/hermes-check-test` drives, and the one 001's checks
# take their stubs from. There is deliberately only one.

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${TESTS_DIR}/../../.." && pwd)"
FIXTURES="${REPO_ROOT}/.specs/005-hermes-check-correctness/fixtures"
# Overridable so a case can be pointed at another copy of the script — which is
# how every case here was shown to fail before the fixes landed. See README.md
# § Red before green.
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

# A stand-in for the urgency model. Stubbing `fasttext` on PATH is not enough:
# hermes-check gates classification on the model *file* existing, so on an
# image that has no /opt/hermes/urgency.bin the classifier is skipped and every
# message lands in the wrong bucket. That is the builder image, which is where
# 006's gate runs these suites — three classification cases failed there while
# passing on any developer machine, because the 800 MB model is provisioned
# there and the suites silently depended on it.
#
# The contents never matter; the stub classifier ignores its argument. Only the
# existence of the path is load-bearing, so an empty file is the honest stub.
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

# The value of a `NAME: value` line in the last run's output. Empty when the
# line is absent, which a case should distinguish from a value of 0.
field() {
  printf '%s\n' "$RUN_OUT" | sed -n "s/^$1: //p" | head -1
}

# Every `  - ` line of the last run, fence content included.
listed_lines() {
  printf '%s\n' "$RUN_OUT" | grep '^  - ' || true
}

# Run hermes-check in a clean environment: an empty environment, a private HOME
# so seen-message state never carries between cases, UTC so rendered times are
# stable, and the stubs ahead of anything real on PATH.
#
#   run_check [--vip <content>] [--home <dir>] [--argv-log <file>] \
#             <gmail-fixture> <calendar-fixture> [VAR=VALUE ...]
#
# A fixture argument naming a file under fixtures/ is passed as that path;
# anything else is handed to the stub verbatim, so a case can feed output that
# could not be stored as a fixture.
#
# --vip seeds the VIP file. Passing it per call rather than through a global is
# deliberate: a global would leak a previous case's VIP list into the next one,
# and "everything is a VIP" is exactly the bug this suite exists to catch.
#
# Sets RUN_OUT, RUN_ERR, RUN_STATUS.
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

  # Restore errexit to whatever the caller had rather than forcing it on: an
  # unconditional `set -e` here would make the next assignment whose command
  # substitution finds nothing kill the whole suite silently.
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

  # RUN_* are the contract with the suites that source this file; shellcheck
  # cannot see those consumers from here.
  # shellcheck disable=SC2034
  RUN_OUT="$(cat "${run_dir}/stdout")"
  # shellcheck disable=SC2034
  RUN_ERR="$(cat "${run_dir}/stderr")"
}

# A private HOME that survives across several run_check calls, for the cases
# that need a second run to see what the first one recorded.
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

# Assertions shared by every case, so that the invariants hold on every fixture
# rather than only where a case thinks to look. This is the general form of the
# negative-OTHER and the abandoned-report findings: both were single fixtures
# that happened to be looked at, and both are properties of every run.
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

  # C4's regression markers. Either string in stderr means an unparsed date
  # reached arithmetic, or a `continue` was written where it cannot act.
  assert_not_contains "no integer-expression errors" "$RUN_ERR" "integer expression expected"
  assert_not_contains "no misplaced continue" "$RUN_ERR" "continue: only meaningful"
}

report_totals() {
  printf '\n%s: %d passed, %d failed\n' "$1" "$TESTS_PASSED" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
