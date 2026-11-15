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

new_store() {
  local dir
  dir="$(mktemp -d "${TMP_ROOT}/store.XXXXXX")"
  printf '[]\n' > "${dir}/jobs.json"
  printf '%s\n' "$dir"
}

run_entrypoint() {
  local run_dir store="" home="" errexit_was_set=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --store) store="$2"; shift 2 ;;
      --home) home="$2"; shift 2 ;;
      *) break ;;
    esac
  done

  run_dir="$(mktemp -d "${TMP_ROOT}/run.XXXXXX")"
  [ -n "$store" ] || store="$(new_store)"
  [ -n "$home" ] || home="${run_dir}/home"
  mkdir -p "${home}/.openclaw"

  case $- in *e*) errexit_was_set="yes" ;; esac
  set +e
  env -i \
    HOME="$home" \
    PATH="${BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    TZ=UTC \
    OPENCLAW_STUB_MARKERS="${run_dir}" \
    OPENCLAW_STUB_STORE="$store" \
    ANTHROPIC_API_KEY=sk-ant-stub \
    HERMES_VIBE=calm \
    HERMES_TONE=direct \
    HERMES_USER_NAME=Tester \
    HERMES_TIMEZONE=UTC \
    HERMES_LOCALE=en-AU \
    HERMES_CRON_SCHEDULE='0 8 * * *' \
    HERMES_QUIET_HOURS_START=20:00 \
    HERMES_QUIET_HOURS_END=08:00 \
    HERMES_CRON_READY_ATTEMPTS=3 \
    HERMES_CRON_REGISTER_ATTEMPTS=2 \
    HERMES_CRON_CALL_TIMEOUT=2 \
    "$@" \
    bash "$ENTRYPOINT" >"${run_dir}/stdout" 2>"${run_dir}/stderr"
  # shellcheck disable=SC2034
  RUN_STATUS=$?
  [ -n "$errexit_was_set" ] && set -e

  # shellcheck disable=SC2034
  RUN_DIR="${run_dir}"
  # shellcheck disable=SC2034
  RUN_HOME="${home}"
  # shellcheck disable=SC2034
  RUN_STORE="${store}"

  if [ "$RUN_STATUS" -eq 0 ] && ! wait_for_registrar "${run_dir}"; then
    fail "the registrar logged no terminal line within the budget"
  fi

  # shellcheck disable=SC2034
  RUN_OUT="$(cat "${run_dir}/stdout")"
  # shellcheck disable=SC2034
  RUN_ERR="$(cat "${run_dir}/stderr")"
}

wait_for_registrar() {
  local run_dir="$1" waited=0 limit="${HARNESS_REGISTRAR_TIMEOUT:-600}"
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

run_log() {
  cat "${RUN_DIR}/stdout" "${RUN_DIR}/stderr" 2>/dev/null
}

gateway_started() {
  [ -f "${RUN_DIR}/gateway-started" ]
}

gateway_gog_account() {
  [ -f "${RUN_DIR}/gateway-gog-account" ] || return 1
  cat "${RUN_DIR}/gateway-gog-account"
}

install_gog_stub() {
  cat > "${BIN_DIR}/gog" <<'STUB'
#!/usr/bin/env bash
if [ -n "${OPENCLAW_STUB_MARKERS:-}" ]; then
  printf '%s\n' "$*" >> "${OPENCLAW_STUB_MARKERS}/calls-gog"
fi
exit 0
STUB
  chmod +x "${BIN_DIR}/gog"
}

store_jobs() {
  cat "${RUN_STORE}/jobs.json"
}

store_count_named() {
  jq --arg name "$1" '[.[] | select(.name == $name)] | length' "${RUN_STORE}/jobs.json"
}

store_job_field() {
  jq -r --arg name "$1" "[.[] | select(.name == \$name)][0] | $2" "${RUN_STORE}/jobs.json"
}

stub_calls() {
  if [ -f "${RUN_DIR}/calls-$1" ]; then
    cat "${RUN_DIR}/calls-$1"
  fi
}

stub_call_count() {
  if [ -f "${RUN_DIR}/calls-$1" ]; then
    wc -l < "${RUN_DIR}/calls-$1" | tr -d ' '
  else
    printf '0\n'
  fi
}

stub_call_order() {
  if [ -f "${RUN_DIR}/call-order" ]; then
    cat "${RUN_DIR}/call-order"
  fi
}

store_write_count() {
  if [ -f "${RUN_STORE}/writes" ]; then
    wc -l < "${RUN_STORE}/writes" | tr -d ' '
  else
    printf '0\n'
  fi
}

report_totals() {
  printf '\n%s: %d passed, %d failed\n' "$1" "$TESTS_PASSED" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
