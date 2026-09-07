#!/usr/bin/env bash
#
# Shared assertions and the sandbox runner for 006's checks. Sourced, not run.
#
# The gate tests the repository; these test the gate. That inversion is why
# this harness is not 005's: 005 runs one script against fixture JSON, while
# every case here runs `bin/test` against a *tree*. The unit under test is a
# repository, so the fixture is a repository — a disposable copy with a defect
# planted in it.
#
# Assertion style follows the plan: one behaviour per case, named
# should_<behaviour>_when_<condition>.

TESTS_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${TESTS_DIR}/../../.." && pwd)"
BIN_TEST="${REPO_ROOT}/bin/test"

# Every case here invokes bin/test, and bin/test's `gate-tests` check invokes
# this suite. Without this variable that is unbounded mutual recursion, which
# presents as a hung CI job rather than as a failure — the worst way for a gate
# to break. Exporting it once here, rather than at each call site, means a case
# added later cannot forget it.
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

# A case that cannot run here, announced rather than quietly dropped — the same
# contract bin/test itself honours for an absent tool. Only the red baseline
# uses it, and only when git history is unavailable; see README.md.
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

# ---------------------------------------------------------------------------
# bin/test
# ---------------------------------------------------------------------------

# bin/test is the subject of every case in this directory. If it is missing
# there is nothing to report but that, and reporting it as a skip would leave a
# green suite for a repository whose declared entrypoint does not exist — the
# exact failure 006 exists to close. So this is a hard stop with a non-zero
# exit.
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

# ---------------------------------------------------------------------------
# Sandboxes
# ---------------------------------------------------------------------------

# A disposable copy of the repository, which a case then damages.
#
# Damage has to happen to a copy: several cases assert that the gate goes red,
# and a case that edited the working tree to prove it would leave the developer
# holding a broken checkout when it failed halfway.
#
# bin/hermes-check-test comes out of every sandbox. Running it costs about
# thirty seconds — the 005 and 001 suites in full — per sandbox, and it reports
# on hermes-check rather than on the gate. The `SKIP hermes-check` that results
# is itself what skip-path-test asserts, so the removal is covered by a case
# instead of being a convenience nobody checks.
#
# .git and .vagrant are excluded: .vagrant is a third of a gigabyte of box
# image, and .git would make each sandbox a live repository whose history a
# case could read by accident instead of the real one's.
make_sandbox() {
  local dir
  dir="$(mktemp -d "${TMP_ROOT}/sandbox.XXXXXX")"
  tar -cf - -C "$REPO_ROOT" --exclude=./.git --exclude=./.vagrant . \
    | tar -xf - -C "$dir"
  rm -f "${dir}/bin/hermes-check-test"
  printf '%s' "$dir"
}

# The planted defect, written out verbatim.
#
# A quoted heredoc, so that what is written here is what lands in the file:
# `${DISCOVERY_PROBE_006:-}` has to survive as text, and inside ordinary quotes
# a linter reading this harness would quite rightly ask why an expansion was
# written in single quotes.
#
# `echo $v` is SC2086 — one of E4's own five findings, and reported at `info`.
# That it counts at all is SPEC Open Question 2 answered by evidence: 001 and
# 005 left the tree clean at the default severity, so the gate can afford to
# fail there and a probe pitched at that level is a fair test of it.
probe_text() {
  cat <<'PROBE'
# Probe planted by 006. Defined, never called: the file it is in behaves
# exactly as it did, and shellcheck still reads it.
discovery_probe_006() { local v="${DISCOVERY_PROBE_006:-}"; echo $v; }
PROBE
}

# Plant a shellcheck violation in a file the gate should be linting.
#
# The probe goes directly under the shebang, never at the end, and is a
# function definition rather than a statement. Some of the files probed are
# executed by the run under test — bin/test is one of them — and appending
# would either run the probe or, in a script that ends without an explicit
# exit, replace its exit status with the definition's. Either way the case
# would be measuring itself.
plant_shellcheck_violation() {
  local file="$1" tmp
  tmp="$(mktemp "${TMP_ROOT}/plant.XXXXXX")"
  {
    head -1 "$file"
    probe_text
    tail -n +2 "$file"
  } > "$tmp"
  # `cat >` rather than `mv`, so the file keeps its mode. A probe that stripped
  # the executable bit would be testing the wrong thing on a gate that
  # discovers by content.
  cat "$tmp" > "$file"
  rm -f "$tmp"
}

# A whole script — shebang, probe, nothing else — at a path a case wants the
# gate to meet. Executable, so that a gate which discovers by mode finds it
# too and exclusion stays the only thing that can keep it out of the run.
#
# It defines a function and ends, so running it is a no-op that exits zero.
# That is what lets the same helper stand in for a script the gate executes as
# well as for one it should never have found.
write_probe_script() {
  local path="$1"
  mkdir -p "$(dirname -- "$path")"
  {
    printf '#!/usr/bin/env bash\n'
    probe_text
  } > "$path"
  chmod +x "$path"
}

# ---------------------------------------------------------------------------
# Running the gate
# ---------------------------------------------------------------------------

# Run bin/test over a sandbox and capture everything it said.
#
#   run_gate --dir <sandbox> [--cwd <dir>] [--env VAR=VALUE]... [-- <args>...]
#
# SKIP_SLOW=1 is always set unless the caller overrides it: the container smoke
# test needs a docker daemon and an image, neither of which a case here has,
# and the skip it produces is asserted by skip-path-test rather than assumed.
#
# With no --cwd the gate is invoked as `./bin/test` from the sandbox root,
# because that is literally what `docker run` does with
# WORKDIR /working-dir and ENTRYPOINT ["./bin/test"]. --cwd invokes it by
# absolute path from elsewhere, which is the local-developer case.
#
# Sets GATE_OUT (stdout and stderr interleaved, as an operator reads them) and
# GATE_STATUS.
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

  # Restore errexit to whatever the caller had rather than forcing it on: the
  # gate is expected to exit non-zero in most cases here, and an unconditional
  # `set -e` would end the suite at the first red run it was written to prove.
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

# The one line per check the output contract promises, in the order they were
# printed. Everything else — tool output for failures, the summary — is noise
# for a case that only cares which checks ran and how they ended.
gate_check_lines() {
  printf '%s\n' "$GATE_OUT" | grep -E '^(PASS|FAIL|SKIP) ' || true
}

# The status word for one check name, or the empty string when the check did
# not report at all. Empty is a distinct and interesting answer: a check that
# printed nothing is not the same as one that passed.
gate_result() {
  printf '%s\n' "$GATE_OUT" \
    | sed -n -E "s/^(PASS|FAIL|SKIP) $1( .*)?\$/\1/p" \
    | head -1
}

# Everything the gate printed after its last per-check line — where the summary
# has to be, since a summary that preceded a check would be summarising a run
# that had not finished.
gate_summary_tail() {
  local last
  last="$(printf '%s\n' "$GATE_OUT" | grep -nE '^(PASS|FAIL|SKIP) ' | tail -1 | cut -d: -f1)"
  if [ -z "$last" ]; then
    printf '%s\n' "$GATE_OUT"
    return 0
  fi
  printf '%s\n' "$GATE_OUT" | tail -n "+$((last + 1))"
}

# The 1-based line number of the first line of GATE_OUT containing $1, or the
# empty string. Used to recover the order in which the gate visited files.
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
