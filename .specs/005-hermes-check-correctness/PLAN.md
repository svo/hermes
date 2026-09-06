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

1. [x] tests: **capture a real `gog --json` response** for Gmail and Calendar and pin the
       fixtures to it (SPEC Open Question 2). Without this the harness encodes the same
       unverified field names that cause C1.
2. [x] tests: add the stub-`gog` harness and `bin/hermes-check-test`.
3. [x] tests: write failing cases for C1–C5, C10, C11 against the current script. **Confirm
       each fails before fixing anything** — this is what makes the fixes verifiable.
4. [x] pipeline: `fetch_json()` with validation; apply at both call sites (C3, C3b).
5. [x] pipeline: replace the flag string with an array (C10).
6. [x] pipeline: fix VIP matching — empty-needle guard and containment direction (C1, C5).
7. [x] pipeline: single-bucket classification; derive `OTHER` by counting (C2).
8. [x] pipeline: fix date parsing; add `UNPARSEABLE_EVENTS` (C4).
9. [x] pipeline: all-day event handling and the bounded sort key (C11).
10. [x] pipeline: add `DATA_SOURCE_ERRORS`/`UNPARSEABLE_EVENTS` to the summary and to
        `ACTION_NEEDED`.
11. [x] instructions: correct the `AGENTS.md` VIP paragraph.
12. [x] tests: assert `shellcheck -s bash hermes-check` exits zero — the 006 precondition.

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

## As built

Every task above is done and every acceptance criterion in `SPEC.md` has at least one case.
`bin/hermes-check-test` runs 140 of them — 97 for this spec, 43 for 001 — with no
credentials and no network. 54 of the 91 behavioural cases fail against the previous
version, and `mutation-check` catches all 37 of its mutations.
`shellcheck -s bash hermes-check` exits zero, which is 006's precondition.

### Open questions, answered

1. **VIP match semantics** — exact address, or exact domain after the `@`, written either
   `example.com` or `@example.com`. Case-insensitive; blank lines and `#` comments ignored.
   No substring or suffix matching in either direction, so C1 and C5 are unrepresentable
   rather than fixed. The rule is stated in `AGENTS.md` and in the README, with a note that
   existing lists should be re-read against it — the old behaviour was wrong in both
   directions, so some lists were flagging more than their owner intended.
2. **`gog` JSON field names** — verified against the emitting source rather than captured
   live, since no account is available here. **Gmail was right; calendar was wrong.** Events
   are raw Google Calendar v3 resources, so `start` and `end` are *objects*. See
   `fixtures/README.md` § Field names, verified. Capturing a live response remains worth
   doing and is noted there.
3. **All-day events** — excluded from conflict detection *and* from next-event (they have no
   start time), and reported separately as `ALL_DAY_EVENTS: <n>`. That is a third additive
   output line beyond the two the Configuration Contract lists, which is what "report them
   separately" required.
4. **The urgency model** — untouched, still the weakest link, still deserves its own spec.

### Deviations from the plan, and why

- **The sort key is `-t$'\t' -k1,1n`, not `-k2,2`.** Parsing moved ahead of sorting: events
  are normalised to epochs once, then ordered, so the start is field 1 and the key is
  numeric. Bounded to one field as the plan requires, and numeric is strictly better — a
  lexical key orders epochs of different digit widths wrongly, which
  `calendar-epoch-width.json` demonstrates.
- **`fetch_json()` returns through a global**, like `sanitize()` does, rather than on stdout.
  A command substitution would have swallowed the error counter and the named error line
  along with it.
- **The stubs live in `tests/` and 001's copies are deleted.** 001's own README said to do
  this once 005 landed. One harness, not two.

### Found while implementing, not in the findings table

All in 005's owned region, all fixed, all covered:

1. **C1 aborted the run.** With `pipefail`, the failing `grep -oE` took the whole script down
   — exit 1, no output — before the VIP check the spec describes was ever reached.
2. **The `|| echo` fallback appended rather than replaced**, so jq saw two documents and a
   failed call still reported counts, printing `EVENTS_TODAY` twice.
3. **The calendar response shape was wrong** — against a real `gog` response the calendar
   produced no next event and no conflicts at all, silently. Open question 2 existed for
   exactly this, and it is the most consequential thing this spec fixes.
4. **`date -d ""` succeeds and answers "now"**, so an event with an empty timestamp was
   placed at the moment the check ran instead of being reported as unreadable.
5. **`jq -e` exits zero over empty input**, so an upstream that succeeded and printed nothing
   validated, and the empty string reached the report as `EVENTS_TODAY: ` with no number.
6. **`read` with `IFS=$'\t'` collapses tab runs**, so an event with no start would have
   adopted its end as its start. Every field is sentinelled now.
7. **Google's `dateTime` + `timeZone` form carries no offset**, so reading it without the
   zone put a 09:00 New York meeting at 09:00 UTC.

4 and 5 were introduced by the fixes themselves and caught by these cases before landing;
6 and 7 were found by `mutation-check` asking why a mutation went unnoticed.

### Found by an adversarial review of the finished change

With everything green, six independent reviewers were pointed at the result. Nine more
defects came back, every one reproduced and every one now fixed and covered — see
`tests/README.md` § What an adversarial review found afterwards for the table.

The headline is that **C11 had come back**. All-day exclusion was keyed on the *text shape*
of gog's `startLocal` string rather than on `start.date`, which is the authoritative signal
and was available in the same jq expression. An all-day event whose `startLocal` carried an
offset overlapped every timed event that day again; a timed event whose `startLocal` was a
bare date disappeared from the report altogether. The pinned fixtures did not catch it
because they only ever carried the shape the code's own comment assumed.

The rest cluster on `.id`, the one attacker-influenced value the change left untouched: an
id of `-e` was read as a `grep` option and silently swallowed every later message; an id
with a newline split one message into phantoms and evicted the seen-message file, causing
re-notification; a missing id dropped the message with no counter at all; and two messages
sharing an id had their fields concatenated. `.id` is now validated, `grep` is called with
`--`, fields are read by position rather than by id, and `UNREADABLE_MESSAGES: <n>` reports
what could not be tracked — a fourth additive output line, and the email path's equivalent
of `UNPARSEABLE_EVENTS`.

Also fixed: the sender address is now taken from the angle-bracketed addr-spec rather than
the first `@`-token anywhere in the header, so a display name can no longer forge VIP status
— which is the guarantee this spec's first user story asks for and which the strict VIP
comparison could not deliver on its own.

The lesson worth keeping: the suite was green for all of this. Fixtures written from a
script's own assumptions test the shapes their author already thought of.
