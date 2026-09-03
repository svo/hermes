#!/usr/bin/env bash
#
# Shared assertions and the hermetic runner for 003's checks. Sourced, not run.
#
# The plan's verification is container-level — docker restart, docker exec
# openclaw cron list. That needs an image and an Anthropic key, so it stays a
# manual acceptance step (see README.md). What runs here is the same assertion
# against the same artefact: the real entrypoint.sh is executed against a stub
# openclaw, and the automation store that stub keeps is what the cases read.
#
# Assertion style follows the plan: one behaviour per case, named
# should_<behaviour>_when_<condition>.

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${TESTS_DIR}/../../.." && pwd)"
# Overridable so a case can be pointed at another copy — which is how these
# were shown to fail against the pre-change entrypoint.
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
      printf '       actual:              %s\n' "$2" >&2
      ;;
  esac
}

assert_not_contains() {
  # assert_not_contains <what> <haystack> <needle>
  case "$2" in
    *"$3"*)
      fail "$1"
      printf '       expected NOT to contain: %s\n' "$3" >&2
      printf '       actual:                  %s\n' "$2" >&2
      ;;
  esac
}

assert_file_absent() {
  # assert_file_absent <what> <path>
  if [ -e "$2" ]; then
    fail "$1"
    printf '       expected absent: %s\n' "$2" >&2
  fi
}

# A shared automation store, so a case can run the entrypoint several times
# against the same "volume" — which is what the restart-idempotency case needs.
#
#   store="$(new_store)"
new_store() {
  local dir
  dir="$(mktemp -d "${TMP_ROOT}/store.XXXXXX")"
  printf '[]\n' > "${dir}/jobs.json"
  printf '%s\n' "$dir"
}

# Run the real entrypoint in a clean environment: empty env, a private HOME so
# no persisted config carries between cases, and a stub openclaw ahead of
# anything real on PATH. The HERMES_* variables are the ones the entrypoint
# already requires; only the briefing ones vary between cases.
#
#   run_entrypoint [--store DIR] [--home DIR] [VAR=VALUE ...]
#
# Sets RUN_OUT, RUN_ERR, RUN_STATUS, RUN_HOME, RUN_STORE, RUN_DIR.
#
# The registrar is a detached subshell that outlives `exec openclaw gateway`,
# so this returns once the entrypoint has finished *and* the registrar has
# logged a terminal line — see wait_for_registrar.
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
  # A comment does not disturb $?, so the disable can sit here.
  # shellcheck disable=SC2034
  RUN_STATUS=$?
  [ -n "$errexit_was_set" ] && set -e

  # RUN_* are the contract with the suites that source this file; shellcheck
  # cannot see those consumers from here.
  # shellcheck disable=SC2034
  RUN_DIR="${run_dir}"
  # shellcheck disable=SC2034
  RUN_HOME="${home}"
  # shellcheck disable=SC2034
  RUN_STORE="${store}"

  # The registrar is forked on the second-to-last line, so a non-zero exit
  # means it was never started and there is nothing to wait for.
  #
  # A timeout is reported rather than discarded. Silently reading a half-
  # written log is how a suite goes green while every case waits out the full
  # budget — and the assertions that follow would be racing the registrar.
  if [ "$RUN_STATUS" -eq 0 ] && ! wait_for_registrar "${run_dir}"; then
    fail "the registrar logged no terminal line within the budget"
  fi

  # shellcheck disable=SC2034
  RUN_OUT="$(cat "${run_dir}/stdout")"
  # shellcheck disable=SC2034
  RUN_ERR="$(cat "${run_dir}/stderr")"
}

# The registrar is forked before `exec`, so it keeps writing to the run's
# stdout and stderr after the entrypoint process is gone. Every terminal path
# emits exactly one of these lines, so waiting for one is waiting for the
# registrar to finish. Bounded: a case that never starts a registrar (a
# configuration error exits before the fork) falls through after the timeout
# rather than hanging.
#
# HARNESS_REGISTRAR_TIMEOUT bounds the wait in twentieths of a second. The
# default is generous; the sensitivity run lowers it, because an entrypoint
# with no registrar in it waits out the whole budget on every case.
wait_for_registrar() {
  local run_dir="$1" waited=0 limit="${HARNESS_REGISTRAR_TIMEOUT:-600}"
  while [ "$waited" -lt "$limit" ]; do
    if grep -Eq '^cron: (registered |.* already registered |giving up )' \
      "${run_dir}/stdout" "${run_dir}/stderr" 2>/dev/null; then
      return 0
    fi
    sleep 0.05
    waited=$((waited + 1))
  done
  return 1
}

# Everything the registrar logged, whichever stream it chose. Success is
# stdout, failure is stderr, and most assertions do not care which.
run_log() {
  cat "${RUN_DIR}/stdout" "${RUN_DIR}/stderr" 2>/dev/null
}

# Did the entrypoint reach `exec openclaw gateway`? The stub records it, so a
# case can assert that a rejected configuration never started the gateway —
# and that a failed registration did not stop it.
gateway_started() {
  [ -f "${RUN_DIR}/gateway-started" ]
}

# The automations the stub holds, as JSON.
store_jobs() {
  cat "${RUN_STORE}/jobs.json"
}

# How many automations carry this name.
store_count_named() {
  jq --arg name "$1" '[.[] | select(.name == $name)] | length' "${RUN_STORE}/jobs.json"
}

# One field of the single automation with this name.
store_job_field() {
  # store_job_field <name> <jq-path-expression>
  jq -r --arg name "$1" "[.[] | select(.name == \$name)][0] | $2" "${RUN_STORE}/jobs.json"
}

# The argv the stub recorded for each `openclaw automations <verb>` call, one
# NUL-free line per call, so a case can assert on the flags actually passed.
stub_calls() {
  # stub_calls <verb>
  if [ -f "${RUN_DIR}/calls-$1" ]; then
    cat "${RUN_DIR}/calls-$1"
  fi
}

stub_call_count() {
  # stub_call_count <verb>
  if [ -f "${RUN_DIR}/calls-$1" ]; then
    wc -l < "${RUN_DIR}/calls-$1" | tr -d ' '
  else
    printf '0\n'
  fi
}

report_totals() {
  printf '\n%s: %d passed, %d failed\n' "$1" "$TESTS_PASSED" "$TESTS_FAILED"
  [ "$TESTS_FAILED" -eq 0 ]
}
