#!/usr/bin/env bash
#
# Shared assertions and the hermetic runner for 007's checks. Sourced, not run.
#
# The plan's verification is container-level — `docker exec hermes openclaw
# config get gateway.bind`, `stat -c '%a' /root/.openclaw/openclaw.json`, a
# real gateway refusing a real unauthenticated bind. That needs the image and
# an Anthropic key, so it stays a manual acceptance step (see README.md).
#
# What runs here is the same assertion by a shorter route: the real
# entrypoint.sh is executed against a stub `openclaw`, and the cases read the
# configuration it wrote, the modes of the files it wrote, the argv it handed
# the gateway, and what it said while doing it.
#
# Assertion style follows the plan: one behaviour per case, named
# should_<behaviour>_when_<condition>.

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${TESTS_DIR}/../../.." && pwd)"
# Overridable so a case can be pointed at another copy — which is how these
# were shown to fail against the pre-change entrypoint, and how mutation-check
# drives them.
ENTRYPOINT="${ENTRYPOINT:-${REPO_ROOT}/infrastructure/ansible/roles/openclaw/files/entrypoint.sh}"

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
CURRENT_CASE=""
CASE_FAILURES=0

TMP_ROOT="$(mktemp -d)"
BIN_DIR="${TMP_ROOT}/bin"
mkdir -p "$BIN_DIR"
cp "${TESTS_DIR}/stub-openclaw" "${BIN_DIR}/openclaw"
cp "${TESTS_DIR}/stub-gog" "${BIN_DIR}/gog"
chmod +x "${BIN_DIR}/openclaw" "${BIN_DIR}/gog"

cleanup() { rm -rf "$TMP_ROOT"; }
trap cleanup EXIT

# The variables a correct start supplies, and nothing else. A case adds what it
# is about — HERMES_GATEWAY_BIND, HERMES_GATEWAY_TOKEN, a channel token — so
# that every run says in one line what it is testing.
#
# The three registrar budgets are pinned to 1: 003's registrar is forked before
# `exec` and would otherwise retry for minutes against a stub that answers
# instantly, and every case here finishes long before the gateway matters.
DEFAULT_ENV=(
  ANTHROPIC_API_KEY=sk-ant-stub-not-a-real-key
  HERMES_VIBE=calm
  HERMES_TONE=direct
  HERMES_USER_NAME=Tester
  HERMES_TIMEZONE=UTC
  HERMES_LOCALE=en-AU
  "HERMES_CRON_SCHEDULE=0 8 * * *"
  HERMES_QUIET_HOURS_START=20:00
  HERMES_QUIET_HOURS_END=08:00
  HERMES_CRON_READY_ATTEMPTS=1
  HERMES_CRON_REGISTER_ATTEMPTS=1
  HERMES_CRON_CALL_TIMEOUT=5
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

# A case that cannot run here, announced rather than quietly dropped — the same
# contract bin/test honours for an absent tool. Silence would be
# indistinguishable from a pass.
skip_case() {
  printf 'SKIP %s (%s)\n' "$1" "$2" >&2
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
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
      ;;
  esac
}

# A HOME several runs can share, so a case can ask what a *restart* does to a
# config volume that already holds a configured container's state. Two of these
# findings are only visible that way: the persisted `lan` an upgrading
# container carries, and the 0644 an older image left behind.
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
#   run_entrypoint [--home DIR] [VAR=VALUE ...]
#
# Sets RUN_OUT, RUN_ERR, RUN_ALL, RUN_STATUS, RUN_HOME, RUN_CONFIG, RUN_DIR,
# RUN_ARGV.
run_entrypoint() {
  local run_dir home="" errexit_was_set=""

  while [ $# -gt 0 ]; do
    case "$1" in
      --home) home="$2"; shift 2 ;;
      *) break ;;
    esac
  done

  run_dir="$(mktemp -d "${TMP_ROOT}/run.XXXXXX")"
  [ -n "$home" ] || home="$(new_home)"

  case $- in *e*) errexit_was_set="yes" ;; esac
  set +e
  env -i \
    HOME="$home" \
    PATH="${BIN_DIR}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    OPENCLAW_STUB_MARKERS="${run_dir}" \
    OPENCLAW_STUB_ARGV_LOG="${run_dir}/argv" \
    GOG_STUB_ARGV_LOG="${run_dir}/gog-argv" \
    "${DEFAULT_ENV[@]}" \
    "$@" \
    bash "$ENTRYPOINT" >"${run_dir}/stdout" 2>"${run_dir}/stderr"
  # A comment does not disturb $?, so the disable can sit here.
  # shellcheck disable=SC2034
  RUN_STATUS=$?
  [ -n "$errexit_was_set" ] && set -e

  # The briefing registrar is 003's, forked just before `exec`. It outlives the
  # entrypoint and keeps writing to these files, so a successful run waits for
  # its one line before anything reads them.
  # Read by the suites that source this file; shellcheck cannot see them from
  # here, and the disable has to sit on the assignment inside the branch as
  # well as on the initialisation.
  # shellcheck disable=SC2034
  RUN_REGISTRAR_STATUS=0
  if [ "$RUN_STATUS" -eq 0 ]; then
    # shellcheck disable=SC2034
    wait_for_registrar "$run_dir" || RUN_REGISTRAR_STATUS=$?
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
  # Both streams together, the way an operator reads `docker logs`. The
  # token-redaction cases have to search everything the container said, not
  # whichever half happened to carry it.
  # shellcheck disable=SC2034
  RUN_ALL="$(cat "${run_dir}/stdout" "${run_dir}/stderr")"
  # shellcheck disable=SC2034
  RUN_ARGV="$(cat "${run_dir}/argv" 2>/dev/null || true)"
}

# Bounded wait for the registrar's single terminal line. A run that never
# forked one falls through after the timeout rather than hanging; that is not
# an error here, because most of these cases are about what happens long before
# the fork.
#
# The budget is deliberately generous — twenty seconds of fiftieth-of-a-second
# ticks. The registrar is a background subshell polling a stub that answers
# instantly, so it normally finishes in milliseconds; but a case that reads its
# line out of RUN_OUT fails on a loaded machine if the budget is tight, and a
# suite that goes red because the box was busy teaches people to re-run rather
# than to read. Cases that depend on the line assert RUN_REGISTRAR_STATUS
# first, so a genuine timeout says so instead of presenting as a missing line.
wait_for_registrar() {
  local run_dir="$1" waited=0 limit="${HARNESS_REGISTRAR_TIMEOUT:-400}"
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

# The argument that followed <flag> in the recorded argv of a single invocation
# of <command>, or the empty string. This is how a case sees what `exec
# openclaw gateway` and `openclaw onboard` were each told, which no file the
# entrypoint writes can answer.
#
#   argv_flag_value <command> <flag> [--occurrence first|last]
#
# Each invocation is kept separate, and that is not tidiness. Two different
# calls log under the command name `gateway`: 003's background registrar
# probing `openclaw gateway health --port <n>`, and the final `exec openclaw
# gateway --port 3000 --bind <mode>`. A reader that flattened them into one
# argument list would answer `--port` from whichever the registrar happened to
# write first — a race, decided by a background subshell, in an assertion about
# the foreground.
#
# `last` is the default because the invocation a case cares about is the one
# the entrypoint ends on. `first` is available for a command that is called
# once and asserted early, and for a case that wants to pin the registrar's own
# probe rather than the exec.
argv_flag_value() {
  local command="$1" flag="$2" occurrence='last'
  if [ "${3:-}" = '--occurrence' ]; then
    occurrence="$4"
  fi
  ARGV_LOG="${RUN_DIR}/argv" ARGV_COMMAND="$command" ARGV_FLAG="$flag" \
  ARGV_OCCURRENCE="$occurrence" node -e "
    const fs = require('fs');
    let text = '';
    try {
      text = fs.readFileSync(process.env.ARGV_LOG, 'utf8');
    } catch {
      process.exit(0);
    }
    const command = process.env.ARGV_COMMAND;
    const flag = process.env.ARGV_FLAG;

    // One argument list per INVOCATION line, never a shared one.
    const invocations = [];
    let current = null;
    for (const line of text.split('\n')) {
      const header = /^INVOCATION \[(.*)\] [0-9]+\$/.exec(line);
      if (header) {
        current = header[1] === command ? [] : null;
        if (current) invocations.push(current);
        continue;
      }
      if (!current) continue;
      const arg = /^ARG \[(.*)\]\$/.exec(line);
      if (arg) current.push(arg[1]);
    }

    const matching = invocations.filter((args) => args.indexOf(flag) !== -1);
    if (matching.length === 0) process.exit(0);
    const args = process.env.ARGV_OCCURRENCE === 'first'
      ? matching[0]
      : matching[matching.length - 1];
    const at = args.indexOf(flag);
    if (at + 1 < args.length) process.stdout.write(args[at + 1]);
  "
}

# How many invocations of <command> were recorded. A case that asserts on
# "the gateway" wants to know whether it is looking at one call or three.
argv_invocation_count() {
  grep -c "^INVOCATION \[$1\] " "${RUN_DIR}/argv" 2>/dev/null || printf '0'
}

# A value out of the config the last run wrote, by dotted path. An absent file
# reads as `absent`: a run rejected in phase 1 writes nothing at all, and that
# is the answer rather than an error.
config_get() {
  CONFIG_PATH="$RUN_CONFIG" CONFIG_QUERY="$1" node -e "
    const fs = require('fs');
    let config;
    try {
      config = JSON.parse(fs.readFileSync(process.env.CONFIG_PATH, 'utf8'));
    } catch {
      process.stdout.write('absent');
      process.exit(0);
    }
    const value = process.env.CONFIG_QUERY.split('.').reduce(
      (node, key) =>
        (node === null || node === undefined || typeof node !== 'object'
          ? undefined
          : node[key]),
      config
    );
    if (value === undefined) {
      process.stdout.write('absent');
    } else {
      process.stdout.write(typeof value === 'string' ? value : JSON.stringify(value));
    }
  "
}

# The same question through the interface README tells an operator to use,
# rather than by reading the file. Prints the stub's answer, or `absent`.
openclaw_config_get() {
  local value
  if value="$(HOME="$RUN_HOME" "${BIN_DIR}/openclaw" config get "$1" 2>/dev/null)"; then
    printf '%s' "$value"
  else
    printf 'absent'
  fi
}

# The octal mode of a path, or the word `absent`. `stat -c` is GNU; BSD stat
# spells it `-f %Lp`, and the local story for this repository includes macOS.
file_mode() {
  if [ ! -e "$1" ]; then
    printf 'absent'
    return 0
  fi
  if stat -c '%a' "$1" 2>/dev/null; then
    return 0
  fi
  stat -f '%Lp' "$1" 2>/dev/null || printf 'unknown'
}

report_totals() {
  if [ "$TESTS_SKIPPED" -gt 0 ]; then
    printf '\n%s: %d passed, %d failed, %d skipped\n' \
      "$1" "$TESTS_PASSED" "$TESTS_FAILED" "$TESTS_SKIPPED"
  else
    printf '\n%s: %d passed, %d failed\n' "$1" "$TESTS_PASSED" "$TESTS_FAILED"
  fi
  [ "$TESTS_FAILED" -eq 0 ]
}
