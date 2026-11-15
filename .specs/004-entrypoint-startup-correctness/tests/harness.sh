#!/usr/bin/env bash

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${TESTS_DIR}/../../.." && pwd)"
ENTRYPOINT="${ENTRYPOINT:-${REPO_ROOT}/infrastructure/ansible/roles/openclaw/files/entrypoint.sh}"

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

DEFAULT_ENV=(
  ANTHROPIC_API_KEY=sk-ant-stub
  HERMES_VIBE=calm
  HERMES_TONE=direct
  HERMES_USER_NAME=Tester
  HERMES_TIMEZONE=UTC
  HERMES_LOCALE=en-AU
  "HERMES_CRON_SCHEDULE=0 8 * * *"
  HERMES_QUIET_HOURS_START=20:00
  HERMES_QUIET_HOURS_END=08:00
)

# shellcheck disable=SC2034
REQUIRED_VARS=(
  ANTHROPIC_API_KEY
  HERMES_VIBE
  HERMES_TONE
  HERMES_USER_NAME
  HERMES_TIMEZONE
  HERMES_LOCALE
  HERMES_CRON_SCHEDULE
  HERMES_QUIET_HOURS_START
  HERMES_QUIET_HOURS_END
)

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
      printf '       actual:              %s\n' "$2" >&2
      ;;
  esac
}

assert_not_contains() {
  case "$2" in
    *"$3"*)
      fail "$1"
      printf '       expected NOT to contain: %s\n' "$3" >&2
      printf '       actual:                  %s\n' "$2" >&2
      ;;
  esac
}

assert_file_absent() {
  if [ -e "$2" ]; then
    fail "$1"
    printf '       expected absent: %s\n' "$2" >&2
  fi
}

new_home() {
  local dir
  dir="$(mktemp -d "${TMP_ROOT}/home.XXXXXX")"
  mkdir -p "${dir}/.openclaw"
  printf '%s\n' "$dir"
}

run_entrypoint() {
  local run_dir home="" errexit_was_set="" entry name candidate skip
  local -a omit=() env_args=()

  while [ $# -gt 0 ]; do
    case "$1" in
      --home) home="$2"; shift 2 ;;
      --omit) omit+=("$2"); shift 2 ;;
      *) break ;;
    esac
  done

  run_dir="$(mktemp -d "${TMP_ROOT}/run.XXXXXX")"
  [ -n "$home" ] || home="$(new_home)"

  for entry in "${DEFAULT_ENV[@]}"; do
    name="${entry%%=*}"
    skip=""
    for candidate in "${omit[@]}"; do
      if [ "$candidate" = "$name" ]; then
        skip="yes"
        break
      fi
    done
    if [ -z "$skip" ]; then
      env_args+=("$entry")
    fi
  done

  case $- in *e*) errexit_was_set="yes" ;; esac
  set +e
  env -i \
    HOME="$home" \
    PATH="${BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    OPENCLAW_STUB_MARKERS="${run_dir}" \
    "${env_args[@]}" \
    "$@" \
    bash "$ENTRYPOINT" >"${run_dir}/stdout" 2>"${run_dir}/stderr"
  # shellcheck disable=SC2034
  RUN_STATUS=$?
  [ -n "$errexit_was_set" ] && set -e

  if [ "$RUN_STATUS" -eq 0 ]; then
    wait_for_registrar "$run_dir"
  fi

  # shellcheck disable=SC2034
  RUN_DIR="${run_dir}"
  # shellcheck disable=SC2034
  RUN_HOME="${home}"
  # shellcheck disable=SC2034
  RUN_CONFIG="${home}/.openclaw/openclaw.json"
  # shellcheck disable=SC2034
  RUN_OUT="$(cat "${run_dir}/stdout")"
  # shellcheck disable=SC2034
  RUN_ERR="$(cat "${run_dir}/stderr")"
}

wait_for_registrar() {
  local run_dir="$1" waited=0 limit="${HARNESS_REGISTRAR_TIMEOUT:-200}"
  while [ "$waited" -lt "$limit" ]; do
    if grep -Eq '^cron: (registered |updated |.* unchanged |declared |giving up )' \
      "${run_dir}/stdout" "${run_dir}/stderr" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
    waited=$((waited + 1))
  done
  return 1
}

gateway_started() {
  [ -f "${RUN_DIR}/gateway-started" ]
}

onboarding_ran() {
  [ -f "${RUN_DIR}/onboarded" ]
}

config_validated() {
  [ -f "${RUN_DIR}/config-validated" ]
}

doctor_ran() {
  [ -f "${RUN_DIR}/doctor-ran" ]
}

config_get() {
  if [ -f "$RUN_CONFIG" ]; then
    jq -c -r "$1" "$RUN_CONFIG"
  else
    printf '%s\n' '{}' | jq -c -r "$1"
  fi
}

fingerprint() {
  if [ -f "$1" ]; then
    sha256sum "$1" | cut -d' ' -f1
  else
    printf 'absent\n'
  fi
}

report_totals() {
  printf '\n%s: %d passed, %d failed\n' "$1" "$TESTS_PASSED" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
