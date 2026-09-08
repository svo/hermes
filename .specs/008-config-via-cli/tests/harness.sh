#!/usr/bin/env bash
#
# Shared assertions and the hermetic runner for 008's checks. Sourced, not run.
#
# `PLAN.md` § Testing Strategy asks for container-level verification —
# `docker exec hermes openclaw exec-policy show`, an operator's tuned
# `tools.exec.timeoutSeconds` surviving a real restart, a real schema rejecting
# a real bad key. That needs the image and an Anthropic key, so it stays a
# manual acceptance step (see README.md).
#
# What runs here is the same assertion by a shorter route: the real
# `entrypoint.sh` runs against a stub `openclaw` that models `config patch`, and
# the cases read the configuration it produced, the argv it used to produce it,
# and what it said while doing it.
#
# The stub is 007's, extended with `config patch`. It is copied rather than
# referenced so that a change to 007's stub cannot silently change what these
# cases mean.
#
# Assertion style follows the plan: one behaviour per case, named
# should_<behaviour>_when_<condition>.

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${TESTS_DIR}/../../.." && pwd)"
# Overridable so a case can be pointed at another copy — which is how these are
# shown to fail against the pre-change entrypoint, and how mutation-check drives
# them.
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
# is about, so that every run says in one line what it is testing.
#
# The three registrar budgets are pinned to 1: 003's registrar is forked before
# `exec` and would otherwise retry for minutes against a stub that answers
# instantly.
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
# config volume that already holds a configured container's state. Most of this
# spec is only visible that way: a sibling survives a restart, or it does not,
# and one start can never tell you which.
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
# RUN_PATCH_STDIN.
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
    OPENCLAW_STUB_PATCH_STDIN="${run_dir}/patch-stdin" \
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
  # redaction cases have to search everything the container said, not whichever
  # half happened to carry it.
  # shellcheck disable=SC2034
  RUN_ALL="$(cat "${run_dir}/stdout" "${run_dir}/stderr")"
  # The document the entrypoint handed the setter, exactly as the setter
  # received it. This is the only way to assert on the *payload* rather than on
  # the file, and the difference matters: a merge that quietly dropped a key
  # would leave the file looking right on a fresh container and wrong on a
  # restart.
  # shellcheck disable=SC2034
  RUN_PATCH_STDIN="$(cat "${run_dir}/patch-stdin" 2>/dev/null || true)"
}

# Bounded wait for the registrar's single terminal line. A run that never forked
# one falls through after the timeout rather than hanging.
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

# How many invocations of <command> were recorded. `config` is what 007's stub
# logs for every `openclaw config ...` call, because it names argv[1] only.
argv_invocation_count() {
  grep -c "^INVOCATION \[$1\] " "${RUN_DIR}/argv" 2>/dev/null || printf '0'
}

# Was <command> called with <arg> anywhere in its argv? This is how a case
# asserts that the setter was *used* — the config coming out right is not the
# same claim, because a block that still wrote the file directly would satisfy
# every value assertion while dissolving nothing.
argv_has_arg() {
  if [ "$(argv_arg_count "$1" "$2")" -gt 0 ]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

# How many invocations of <command> carried <arg>. `config` is not specific
# enough to count on its own: 007's stub names an invocation by argv[1], so
# `config patch` and phase 3's `config validate` are both logged as `config`.
argv_arg_count() {
  local command="$1" wanted="$2"
  ARGV_LOG="${RUN_DIR}/argv" ARGV_COMMAND="$command" ARGV_WANTED="$wanted" node -e "
    const fs = require('fs');
    let text = '';
    try {
      text = fs.readFileSync(process.env.ARGV_LOG, 'utf8');
    } catch {
      process.stdout.write('no');
      process.exit(0);
    }
    const command = process.env.ARGV_COMMAND;
    const wanted = process.env.ARGV_WANTED;

    // One argument list per INVOCATION line, never a shared one: 003's
    // registrar logs concurrently from a background subshell.
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
    process.stdout.write(String(
      invocations.filter((args) => args.indexOf(wanted) !== -1).length
    ));
  "
}

# A value out of the config the last run wrote, by dotted path. An absent file
# reads as `absent`: a run rejected in phase 1 writes nothing at all, and that is
# the answer rather than an error.
#
# Bracket notation for one segment, because a model id contains dots:
# `agents.defaults.models[anthropic/claude-haiku-4-5]`.
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
    const path = [];
    for (const part of process.env.CONFIG_QUERY.split('.')) {
      const bracket = /^(.*)\[(.+)\]\$/.exec(part);
      if (bracket) {
        if (bracket[1]) path.push(bracket[1]);
        path.push(bracket[2]);
      } else {
        path.push(part);
      }
    }
    const value = path.reduce(
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

# The same question, asked of the payload the entrypoint sent rather than of the
# file that came out. `absent` when the key is not mentioned; `null` when it is
# mentioned as a deletion, which is a different statement and has to stay
# distinguishable from both `absent` and a written value.
patch_get() {
  PATCH_DOC="$RUN_PATCH_STDIN" PATCH_QUERY="$1" node -e "
    let patch;
    try {
      patch = JSON.parse(process.env.PATCH_DOC);
    } catch {
      process.stdout.write('absent');
      process.exit(0);
    }
    let node = patch;
    for (const key of process.env.PATCH_QUERY.split('.')) {
      if (node === null || typeof node !== 'object' ||
          !Object.prototype.hasOwnProperty.call(node, key)) {
        process.stdout.write('absent');
        process.exit(0);
      }
      node = node[key];
    }
    process.stdout.write(typeof node === 'string' ? node : JSON.stringify(node));
  "
}

# Seed a config volume with keys an operator set by hand, before a start runs
# against it. This is the whole of acceptance criterion 3: the sibling has to
# exist before the restart that must not remove it.
#
#   seed_config <home> <json>
seed_config() {
  local home="$1" document="$2"
  mkdir -p "${home}/.openclaw"
  SEED_TARGET="${home}/.openclaw/openclaw.json" SEED_DOC="$document" node -e "
    const fs = require('fs');
    const target = process.env.SEED_TARGET;
    let config = {};
    try {
      config = JSON.parse(fs.readFileSync(target, 'utf8'));
    } catch {}
    const merge = (into, from) => {
      for (const [key, value] of Object.entries(from)) {
        if (value !== null && typeof value === 'object' && !Array.isArray(value) &&
            into[key] !== null && typeof into[key] === 'object' &&
            !Array.isArray(into[key])) {
          merge(into[key], value);
        } else {
          into[key] = value;
        }
      }
      return into;
    };
    merge(config, JSON.parse(process.env.SEED_DOC));
    fs.writeFileSync(target, JSON.stringify(config, null, 2) + '\n');
  "
}

# Does a path exist under $HOME after the run? `exec-approvals.json` is asserted
# absent on a fresh start and gone after a migration, and "absent" is the
# answer either way rather than an error.
home_file_present() {
  if [ -e "${RUN_HOME}/$1" ]; then
    printf 'yes'
  else
    printf 'no'
  fi
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
