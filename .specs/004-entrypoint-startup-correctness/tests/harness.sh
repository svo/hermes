#!/usr/bin/env bash
#
# Shared assertions and the hermetic runner for 004's checks. Sourced, not run.
#
# The plan's verification is container-level — docker run with a variable
# omitted, then `docker exec hermes openclaw config get`. That needs the image
# and an Anthropic key, so it stays a manual acceptance step (see README.md).
# What runs here is the same assertion against the same artefact: the real
# entrypoint.sh is executed against a stub openclaw, and the openclaw.json it
# writes — or conspicuously does not write — is what the cases read.
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

# The variables a correct start supplies. A case names the ones it wants
# *omitted*, which is what `docker run` without a -e actually does — an empty
# value is a different input, and the two used to fail in different ways.
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

# Every variable the entrypoint requires unconditionally. The permutation
# matrix walks this list, and it is deliberately a separate declaration from
# DEFAULT_ENV so that a variable added to one and not the other shows up as a
# failing case rather than as silently reduced coverage.
#
# Consumed by the suites that source this file; shellcheck cannot see them.
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

# A HOME several runs can share, so a case can ask what a *restart* does to a
# config volume that already holds a configured container's state.
new_home() {
  local dir
  dir="$(mktemp -d "${TMP_ROOT}/home.XXXXXX")"
  mkdir -p "${dir}/.openclaw"
  printf '%s\n' "$dir"
}

# Run the real entrypoint in a clean environment: empty env, a private HOME so
# no persisted config carries between cases, and a stub openclaw ahead of
# anything real on PATH.
#
#   run_entrypoint [--home DIR] [--omit VAR]... [VAR=VALUE ...]
#
# --omit drops one of DEFAULT_ENV entirely rather than blanking it. Sets
# RUN_OUT, RUN_ERR, RUN_STATUS, RUN_HOME, RUN_CONFIG, RUN_DIR.
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
  # A comment does not disturb $?, so the disable can sit here.
  # shellcheck disable=SC2034
  RUN_STATUS=$?
  [ -n "$errexit_was_set" ] && set -e

  # The briefing registrar is 003's, forked just before `exec`. It outlives the
  # entrypoint and keeps writing to these files, so a successful run waits for
  # its one line before anything reads them.
  if [ "$RUN_STATUS" -eq 0 ]; then
    wait_for_registrar "$run_dir"
  fi

  # RUN_* are the contract with the suites that source this file; shellcheck
  # cannot see those consumers from here.
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

# Bounded wait for the registrar's single terminal line. A run that never
# forked one falls through after the timeout rather than hanging; that is not
# an error here, because most of these cases are about what happens long before
# the fork.
wait_for_registrar() {
  local run_dir="$1" waited=0 limit="${HARNESS_REGISTRAR_TIMEOUT:-200}"
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

# Did the entrypoint reach `exec openclaw gateway`?
gateway_started() {
  [ -f "${RUN_DIR}/gateway-started" ]
}

# Did it get as far as onboarding — the first thing that writes?
onboarding_ran() {
  [ -f "${RUN_DIR}/onboarded" ]
}

# Did the phase 3 gate run?
config_validated() {
  [ -f "${RUN_DIR}/config-validated" ]
}

# A value out of the config the last run wrote, by jq path expression. An
# absent file reads as an empty config: a run rejected in phase 1 writes
# nothing at all, and that is the answer, not a jq failure.
config_get() {
  if [ -f "$RUN_CONFIG" ]; then
    jq -c -r "$1" "$RUN_CONFIG"
  else
    printf '%s\n' '{}' | jq -c -r "$1"
  fi
}

# The fingerprint of a file, or the word `absent`. The permutation matrix
# compares this either side of a rejected start: identical means phase 1 really
# did precede every write, rather than merely appearing earlier in the file.
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
