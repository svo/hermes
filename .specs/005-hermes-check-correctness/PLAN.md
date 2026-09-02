# Plan: hermes-check correctness

> Adapted from the `plan` skill — see [`.specs/README.md`](../README.md) § Template adaptation.
> Spec: [`SPEC.md`](SPEC.md)

## Implementation Strategy

Build the test harness **first**. Every bug in this spec was found by running the code, and
none of them is visible by reading it — `|| continue` looks like it skips, `grep -qiF ""`
looks like a match test, and the subtraction looks like arithmetic. Without a harness the
fixes are unverifiable and the next five bugs land the same way.

**The stub-`gog` harness** is the enabling change: a fake `gog` placed earlier on `PATH`
that prints fixture JSON chosen by an environment variable. It makes `hermes-check` runnable
end-to-end with no credentials, no network, and no Google account — turning a script that
can only be tested in production into one that can be tested in CI. It is the highest-value
artifact in this programme and 006 depends on it.

Then fix in dependency order. Two changes are *structural* rather than local patches:

- **Classification** becomes one bucket per message. `OTHER` is derived by counting the
  bucket, never by subtraction — which makes C2 unrepresentable rather than merely fixed.
- **Data acquisition** gets a `fetch_json()` wrapper that validates with `jq -e . >/dev/null`
  before returning, falling back to a documented empty structure and incrementing
  `DATA_SOURCE_ERRORS`. This removes the whole C3 class, including the valid-exit-non-JSON
  variant the current `|| echo` guard misses.

Do not "fix" the shellcheck SC2086 findings by quoting. `$gog_account_flag` unquoted is
load-bearing: quoting it passes an empty string argument when `GOG_GOOGLE_ACCOUNT` is unset.
Convert to an array (`gog_args=()`), which satisfies shellcheck and preserves behaviour.

## Layer Changes

### Provisioning
None. `roles/openclaw/tasks/main.yml:29-34` copies the script unchanged.

### Agent pipeline (`roles/openclaw/files/hermes-check`)
Owned region: matching, counting, acquisition, date handling. 001 owns `sanitize_field()`
and the emit sites — call the helper, do not reimplement it.

- **Acquisition** — add `fetch_json()`; use at `:38` and `:112`. Validate before returning.
- **Flags** — replace `gog_account_flag` string (`:13-16`) with `gog_args=()`; expand as
  `"${gog_args[@]}"` at both call sites.
- **VIP** (`:71-76`) — skip when the needle is empty; match with correct containment
  direction (iterate VIP entries and test against the sender, not the reverse); apply the
  semantics chosen in SPEC Open Question 1.
- **Classification** (`:60-85`) — assign exactly one bucket per message with an explicit
  precedence (urgent > vip > other); increment only that bucket's counter.
- **Counting** (`:100`) — emit the `other` counter directly. Add an internal assertion that
  the three buckets sum to `new_count`.
- **Dates** (`:121-132`, `:148-164`) — remove `|| continue` from substitutions; parse into a
  variable, test emptiness in the loop body, `continue` there. Count unparseable events.
- **All-day events** — detect date-only `start` and handle per SPEC Open Question 3.
- **Sorting** (`:164`) — `sort -t$'\t' -k2,2` to bound the sort key to one field.
- **Summary** — add `DATA_SOURCE_ERRORS` and `UNPARSEABLE_EVENTS`; include both in
  `ACTION_NEEDED`.

### Agent instructions
- `AGENTS.md` VIP paragraph — state the actual matching rule.

### Image & CI
- `bin/hermes-check-test` — the harness runner.
- `.specs/005-hermes-check-correctness/fixtures/` — shared with 001 and 006.

## Configuration Contract

| In | Out |
|---|---|
| `GOG_GOOGLE_ACCOUNT` (optional) | `--account` passed only when non-empty |
| fixture JSON via stub `gog` | deterministic, credential-free runs |
| — | `DATA_SOURCE_ERRORS: <n>`, `UNPARSEABLE_EVENTS: <n>` |

## Task List

1. [ ] tests: **capture a real `gog --json` response** for Gmail and Calendar and pin the
       fixtures to it (SPEC Open Question 2). Without this the harness encodes the same
       unverified field names that cause C1.
2. [ ] tests: add the stub-`gog` harness and `bin/hermes-check-test`.
3. [ ] tests: write failing cases for C1–C5, C10, C11 against the current script. **Confirm
       each fails before fixing anything** — this is what makes the fixes verifiable.
4. [ ] pipeline: `fetch_json()` with validation; apply at both call sites (C3, C3b).
5. [ ] pipeline: replace the flag string with an array (C10).
6. [ ] pipeline: fix VIP matching — empty-needle guard and containment direction (C1, C5).
7. [ ] pipeline: single-bucket classification; derive `OTHER` by counting (C2).
8. [ ] pipeline: fix date parsing; add `UNPARSEABLE_EVENTS` (C4).
9. [ ] pipeline: all-day event handling and the bounded sort key (C11).
10. [ ] pipeline: add `DATA_SOURCE_ERRORS`/`UNPARSEABLE_EVENTS` to the summary and to
        `ACTION_NEEDED`.
11. [ ] instructions: correct the `AGENTS.md` VIP paragraph.
12. [ ] tests: assert `shellcheck -s bash hermes-check` exits zero — the 006 precondition.

## Testing Strategy

No test framework exists; the harness is the framework.

- **Stub `gog`** — a script earlier on `PATH` that emits `$FIXTURE` and exits with
  `$FIXTURE_EXIT`. Covers: valid JSON, malformed JSON with exit 0 (the C3b case the current
  guard misses), non-zero exit, empty output, and missing `.from`.
- **Red-then-green** — task 3 requires every case to fail first. A test that has never
  failed proves nothing.
- **Invariant assertion** — `URGENT + VIP + OTHER == NEW_UNREAD` on every fixture, not just
  the overlap case. This is the general form of C2.
- **Output-completeness assertion** — every fixture, including total upstream failure, must
  produce exactly one `--- SUMMARY ---`. Shared with 001's forged-summary case.
- **stderr assertion** — no `integer expression expected` and no `continue: only meaningful`
  in any run. Those strings are C4's regression markers.
- **Lint** — `shellcheck -s bash` clean, and specifically SC2086/SC2106-free.
- Naming: `should_<behaviour>_when_<condition>`, one behaviour per case.

Coverage target: every SPEC acceptance criterion maps to at least one fixture. Live
verification against a real Google account remains a manual acceptance step.

## Operability Plan

- `DATA_SOURCE_ERRORS` and `UNPARSEABLE_EVENTS` in every summary; either non-zero sets
  `ACTION_NEEDED`, so degraded monitoring notifies rather than hides.
- The script never exits non-zero without output; a complete report is emitted on every path.
- Operator check: `docker exec hermes hermes-check | tail -5`.

## Risks and Mitigations

- **Risk:** fixtures encode guessed `gog` field names, so tests pass while production stays
  broken. → **Mitigation:** task 1 pins fixtures to a captured real response, and it is
  sequenced first for exactly this reason.
- **Risk:** `set -e` removal to survive failures masks genuine errors. → **Mitigation:** keep
  `set -euo pipefail`; handle failures explicitly in `fetch_json()` rather than relaxing the
  shell options.
- **Risk:** changing VIP semantics silently reclassifies a user's existing list.
  → **Mitigation:** decide Open Question 1 explicitly and note the change in the README; the
  current behaviour is broken in both directions, so some change is unavoidable.
- **Risk:** editing the same file as 001 causes conflicts. → **Mitigation:** 001 lands first;
  regions are declared; 005 calls `sanitize_field()` rather than touching emit sites.
- **Risk:** `ACTION_NEEDED` on data-source errors makes a flaky upstream noisy.
  → **Mitigation:** acceptable — silent broken monitoring is the worse failure. Revisit with
  a consecutive-failure threshold if it proves noisy in practice.
- **Risk:** the harness drifts from the installed script if `tasks/main.yml` ever transforms
  it. → **Mitigation:** the copy task is verbatim; assert the tested path and the installed
  path are the same file in `bin/test`.
