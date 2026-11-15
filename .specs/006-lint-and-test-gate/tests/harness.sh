#!/usr/bin/env bash

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${TESTS_DIR}/../../.." && pwd)"
BIN_TEST="${REPO_ROOT}/bin/test"

export HERMES_GATE_TEST=1

TESTS_PASSED=0
TESTS_FAILED=0
TESTS_SKIPPED=0
CURRENT_CASE=""
CASE_FAILURES=0

TMP_ROOT="$(mktemp -d)"

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

count_exact_lines() {
  printf '%s\n' "$1" | grep -cxF -- "$2" || true
}

count_matching_lines() {
  printf '%s\n' "$1" | grep -c -- "$2" || true
}

require_bin_test() {
  if [ ! -f "$BIN_TEST" ]; then
    printf 'bin/test not found at %s\n' "$BIN_TEST" >&2
    printf 'The gate is the subject of these cases; there is nothing to check without it.\n' >&2
    exit 1
  fi
  if [ ! -x "$BIN_TEST" ]; then
    printf 'bin/test at %s is not executable\n' "$BIN_TEST" >&2
    printf 'builder.pkr.hcl declares ENTRYPOINT ["./bin/test"]; docker cannot run a file without +x.\n' >&2
    exit 1
  fi
}

make_sandbox() {
  local dir
  dir="$(mktemp -d "${TMP_ROOT}/sandbox.XXXXXX")"
  tar -cf - -C "$REPO_ROOT" --exclude=./.git --exclude=./.vagrant . \
    | tar -xf - -C "$dir"
  rm -f "${dir}/bin/hermes-check-test"
  printf '%s' "$dir"
}

probe_text() {
  cat <<'PROBE'
discovery_probe_006() { local v="${DISCOVERY_PROBE_006:-}"; echo $v; }
PROBE
}

plant_shellcheck_violation() {
  local file="$1" tmp
  tmp="$(mktemp "${TMP_ROOT}/plant.XXXXXX")"
  {
    head -1 "$file"
    probe_text
    tail -n +2 "$file"
  } > "$tmp"
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

write_probe_script() {
  local path="$1"
  mkdir -p "$(dirname -- "$path")"
  {
    printf '#!/usr/bin/env bash\n'
    probe_text
  } > "$path"
  chmod +x "$path"
}

run_gate() {
  local dir="" cwd="" errexit_was_set=""
  local -a extra_env=("SKIP_SLOW=1") args=()
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --dir) dir="$2"; shift 2 ;;
      --cwd) cwd="$2"; shift 2 ;;
      --env) extra_env+=("$2"); shift 2 ;;
      --) shift; args=("$@"); break ;;
      *) break ;;
    esac
  done

  if [ -z "$dir" ]; then
    printf 'run_gate: --dir is required\n' >&2
    return 2
  fi

  case $- in *e*) errexit_was_set="yes" ;; esac
  set +e
  if [ -n "$cwd" ]; then
    GATE_OUT="$(cd -- "$cwd" && env "${extra_env[@]}" "${dir}/bin/test" "${args[@]}" 2>&1)"
  else
    GATE_OUT="$(cd -- "$dir" && env "${extra_env[@]}" ./bin/test "${args[@]}" 2>&1)"
  fi
  # shellcheck disable=SC2034  # read by the suites that source this file
  GATE_STATUS=$?
  [ -n "$errexit_was_set" ] && set -e
  return 0
}

gate_check_lines() {
  printf '%s\n' "$GATE_OUT" | grep -E '^(PASS|FAIL|SKIP) ' || true
}

gate_result() {
  printf '%s\n' "$GATE_OUT" \
    | sed -n -E "s/^(PASS|FAIL|SKIP) $1( .*)?\$/\1/p" \
    | head -1
}

gate_summary_tail() {
  local last
  last="$(printf '%s\n' "$GATE_OUT" | grep -nE '^(PASS|FAIL|SKIP) ' | tail -1 | cut -d: -f1)"
  if [ -z "$last" ]; then
    printf '%s\n' "$GATE_OUT"
    return 0
  fi
  printf '%s\n' "$GATE_OUT" | tail -n "+$((last + 1))"
}

first_output_line() {
  printf '%s\n' "$GATE_OUT" | grep -nF -- "$1" | head -1 | cut -d: -f1
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
