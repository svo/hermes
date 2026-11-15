#!/usr/bin/env bash

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${TESTS_DIR}/../../.." && pwd)"
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

skip_case() {
  printf 'SKIP %s (%s)\n' "$1" "$2" >&2
  TESTS_SKIPPED=$((TESTS_SKIPPED + 1))
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
      ;;
  esac
}

new_home() {
  local dir
  dir="$(mktemp -d "${TMP_ROOT}/home.XXXXXX")"
  mkdir -p "${dir}/.openclaw"
  printf '%s\n' "$dir"
}

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
  # shellcheck disable=SC2034
  RUN_STATUS=$?
  [ -n "$errexit_was_set" ] && set -e

  # shellcheck disable=SC2034
  RUN_REGISTRAR_STATUS=0
  if [ "$RUN_STATUS" -eq 0 ]; then
    # shellcheck disable=SC2034
    wait_for_registrar "$run_dir" || RUN_REGISTRAR_STATUS=$?
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
  # shellcheck disable=SC2034
  RUN_ALL="$(cat "${run_dir}/stdout" "${run_dir}/stderr")"
  # shellcheck disable=SC2034
  RUN_PATCH_STDIN="$(cat "${run_dir}/patch-stdin" 2>/dev/null || true)"
}

wait_for_registrar() {
  local run_dir="$1" waited=0 limit="${HARNESS_REGISTRAR_TIMEOUT:-400}"
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

argv_invocation_count() {
  grep -c "^INVOCATION \[$1\] " "${RUN_DIR}/argv" 2>/dev/null || printf '0'
}

argv_has_arg() {
  if [ "$(argv_arg_count "$1" "$2")" -gt 0 ]; then
    printf 'yes'
  else
    printf 'no'
  fi
}

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
