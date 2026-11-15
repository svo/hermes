#!/usr/bin/env bash

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${TESTS_DIR}/../../.." && pwd)"
ENTRYPOINT="${ENTRYPOINT:-${REPO_ROOT}/infrastructure/ansible/roles/openclaw/files/entrypoint.sh}"
MANIFEST="${MANIFEST:-${REPO_ROOT}/infrastructure/slack-app-manifest.json}"

TESTS_PASSED=0
TESTS_FAILED=0
CURRENT_CASE=""
CASE_FAILURES=0

TMP_ROOT="$(mktemp -d)"
BIN_DIR="${TMP_ROOT}/bin"
mkdir -p "$BIN_DIR"
cp "${TESTS_DIR}/stub-openclaw" "${BIN_DIR}/openclaw"
chmod +x "${BIN_DIR}/openclaw"

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

run_entrypoint() {
  local run_dir errexit_was_set=""
  run_dir="$(mktemp -d "${TMP_ROOT}/run.XXXXXX")"
  mkdir -p "${run_dir}/home/.openclaw"

  case $- in *e*) errexit_was_set="yes" ;; esac
  set +e
  env -i \
    HOME="${run_dir}/home" \
    PATH="${BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    TZ=UTC \
    OPENCLAW_STUB_MARKERS="${run_dir}" \
    ANTHROPIC_API_KEY=sk-ant-stub \
    HERMES_VIBE=calm \
    HERMES_TONE=direct \
    HERMES_USER_NAME=Tester \
    HERMES_TIMEZONE=UTC \
    HERMES_LOCALE=en-AU \
    HERMES_CRON_SCHEDULE='0 8 * * *' \
    HERMES_QUIET_HOURS_START=20:00 \
    HERMES_QUIET_HOURS_END=08:00 \
    "$@" \
    bash "$ENTRYPOINT" >"${run_dir}/stdout" 2>"${run_dir}/stderr"
  # shellcheck disable=SC2034
  RUN_STATUS=$?
  [ -n "$errexit_was_set" ] && set -e

  # shellcheck disable=SC2034
  RUN_OUT="$(cat "${run_dir}/stdout")"
  # shellcheck disable=SC2034
  RUN_ERR="$(cat "${run_dir}/stderr")"
  # shellcheck disable=SC2034
  RUN_HOME="${run_dir}/home"
  # shellcheck disable=SC2034
  RUN_CONFIG="${run_dir}/home/.openclaw/openclaw.json"
  # shellcheck disable=SC2034
  RUN_DIR="${run_dir}"
}

gateway_started() {
  [ -f "${RUN_DIR}/gateway-started" ]
}

config_get() {
  if [ -f "$RUN_CONFIG" ]; then
    jq -c -r "$1" "$RUN_CONFIG"
  else
    printf '%s\n' '{}' | jq -c -r "$1"
  fi
}

config_validate() {
  env HOME="$RUN_HOME" PATH="${BIN_DIR}:${PATH}" openclaw config validate --json
}

report_totals() {
  printf '\n%s: %d passed, %d failed\n' "$1" "$TESTS_PASSED" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
