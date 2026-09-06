# 005 checks

Verification for [SPEC.md](../SPEC.md). No credentials, no network, no Google account — a
stub `gog` on `PATH` serves fixture JSON and a stub `fasttext` makes urgency classification
deterministic.

```bash
bin/hermes-check-test          # everything that verifies hermes-check
.specs/005-hermes-check-correctness/tests/run   # just this spec's cases
```

| File | What it is |
|---|---|
| `run` | Entry point for 005. Accumulates failures rather than stopping at the first. |
| `harness.sh` | Shared assertions and the hermetic runner. Sourced, not run. |
| `vip-matching-test` | C1 and C5 — who counts as a VIP, and who does not. |
| `classification-test` | C2 — one bucket per message, and the counts that follow. |
| `message-identity-test` | `.id` and the sender address — the two values the pipeline trusts. |
| `data-source-test` | C3 and C3b — what a broken upstream call produces. |
| `calendar-dates-test` | C4 and C11 — unreadable dates, all-day events, ordering. |
| `upstream-shape-test` | SPEC Open Question 2 — the response shape `gog` really emits. |
| `gog-invocation-test` | C10 — what `gog` is actually called with. |
| `lint-test` | The shellcheck gate 006 depends on. |
| `mutation-check` | Sensitivity check. Not part of `run`; see below. |
| `stub-gog` | Fake `gog`: prints a fixture, exits with a chosen status, logs its argv. |
| `stub-fasttext` | Fake urgency classifier, so bucket assignment is identical everywhere. |

Ninety-seven cases: 20 in `vip-matching-test`, 8 in `classification-test`, 11 in
`message-identity-test`, 11 in `data-source-test`, 21 in `calendar-dates-test`, 14 in
`upstream-shape-test`, 6 in `gog-invocation-test`, 6 in `lint-test`.

Fixtures live in [`../fixtures/`](../fixtures/README.md), shared with 001 and 006.

## One harness

`PLAN.md` gives `bin/hermes-check-test` as the harness runner, and 001's cases were carrying
their own copies of the stubs until it existed. It exists now, so 001's `harness.sh` copies
the stubs from here and its own copies are deleted — which is what 001's `tests/README.md`
said to do when 005 landed. Two harnesses would drift, and the thing they both test is one
file.

## Red before green

Every case here was run against the pre-change script first. Against the original
`hermes-check`:

| Suite | Failing before | Total |
|---|---|---|
| `vip-matching-test` | 5 | 20 |
| `classification-test` | 2 | 8 |
| `message-identity-test` | 10 | 11 |
| `data-source-test` | 11 | 11 |
| `calendar-dates-test` | 15 | 21 |
| `upstream-shape-test` | 10 | 14 |
| `gog-invocation-test` | 1 | 6 |
| **total** | **54** | **91** |

(`lint-test` is excluded: it lints whichever file it is pointed at, so running it against the
old script is a statement about that file rather than a red baseline.)

To repeat that, point the suites at a copy of the old file:

```bash
HERMES_CHECK=/path/to/old/hermes-check .specs/005-hermes-check-correctness/tests/run
```

**The cases that pass against the original are the interesting ones**, and they are not
padding:

- Most VIP cases pass because substring containment does match an exact string. The five
  that fail are precisely C1 (a sender with no readable address) and C5 (an entry that
  merely contains the sender's domain). The rest are there so the *new* rule cannot drift
  into being too narrow — a fix that stopped matching `example.com` for `bob@example.com`
  would be caught by them and by nothing else.
- Only two classification cases fail, because the old arithmetic was right whenever the
  buckets did not overlap. `OTHER` went negative only for a message that was both urgent
  and VIP. That is why `assert_universal_invariants` runs in all 91 cases rather than only
  in the one named for it: the general form of C2 is "the counts disagree with the listing",
  and one fixture was never going to cover it. It checks the exit status, that there is
  exactly one `--- SUMMARY ---` and one `ACTION_NEEDED`, that `URGENT + VIP + OTHER` equals
  `NEW_UNREAD` with `OTHER >= 0`, and that neither of C4's stderr markers appears — on every
  path, including a total upstream failure and a `gog` that is not installed.
- `gog-invocation-test` mostly passes because the original's unquoted expansion did produce
  the right two arguments when the account was set. It was still wrong — the shellcheck
  warning it raised was real, and the obvious fix for that warning would have broken the
  unset case. The one failing case is an account containing a space, which the string form
  could not represent either way round.

## What the checks found that the spec did not

Three defects surfaced here that are not in `SPEC.md`'s findings table. All three are in
005's owned region and all three are fixed:

1. **C1's symptom was worse than recorded.** The spec says an unparseable `From` makes every
   message a VIP. In the tree as it stood, `grep -oE` exits 1 when it finds no address, and
   under `pipefail` that aborted the whole run — exit 1, no output at all, before any count
   was printed. Both failure modes had to be closed; fixing only the abort would have
   revealed the one the spec describes.
2. **The `|| echo` fallback appended rather than replaced.** `$(gog ... || echo '{...}')`
   runs `echo` *after* the failing command has already written its output, and both land in
   the same substitution. jq was handed two documents and answered for both, so a failed
   call reported counts and `EVENTS_TODAY` printed twice.
3. **The calendar response shape was wrong** — see [`../fixtures/README.md`](../fixtures/README.md)
   § Field names, verified. Against a real `gog` response the calendar analysis produced
   nothing at all.

And two the fixes themselves introduced, both caught by these cases before they landed:
`jq -e` exits zero over empty input, so a call that succeeded and printed nothing validated;
and `read` with `IFS=$'\t'` collapses a run of tabs into one delimiter, so an empty middle
field shifted every later field left.

## What an adversarial review found afterwards

With everything above green, six independent reviewers were pointed at the finished change,
each with one lens and told to demonstrate defects rather than describe them. Two survived
the run; between them they found nine, all reproduced and all now fixed and covered here.

They matter because they are the *same defect class this spec exists to close* — a silent
loss, in a report that reads as an ordinary quiet day — and because the suite above was
green throughout. Fixtures written from the script's own assumptions test the shapes the
author already thought of.

| Finding | What happened | Now covered by |
|---|---|---|
| `.id` of `-e` read as a `grep` option | `grep` took the seen-file as its *pattern*, found no file operand, read the loop's own input, and swallowed every remaining message. One decoy emptied the inbox; `ACTION_NEEDED: no` | `should_read_every_message_when_an_id_looks_like_a_grep_option` |
| `.id` of `--version` | `grep` printed its own banner onto the report — outside the fence, past the sanitizer, angle brackets and all | `should_not_emit_grep_output_when_an_id_is_a_grep_long_option` |
| VIP forgeable from the display name | the address was the first `@`-token *anywhere* in the header, so `"boss@example.com" <mallory@evil.invalid>` was a VIP — and a real VIP behind a list address was demoted | `should_not_flag_vip_when_the_display_name_impersonates_one`, `should_flag_vip_when_a_decoy_address_precedes_the_real_sender` |
| `\|\| from_addr=""` swallowed EPIPE | with `pipefail`, `grep \| head -1` exits 141 once grep fills the pipe; a correctly-extracted VIP address was then thrown away on exit status alone | `should_keep_a_correct_sender_when_the_header_is_long_enough_to_fill_a_pipe` |
| a message with no `.id` vanished | no counter, no error, and no total to reconcile against — the email path had no `UNPARSEABLE_EVENTS` equivalent | `should_report_an_unreadable_message_when_it_has_no_id` |
| a newline in `.id` | split one message into content-free phantoms, and every fragment went into the seen file, evicting the real ids under the 200-line cap and re-notifying messages already seen | `should_report_an_unreadable_message_when_its_id_contains_a_newline`, `should_not_evict_the_seen_file_when_an_id_contains_many_newlines` |
| two messages sharing an `.id` | field lookups by id concatenated both subjects and both senders, rendered a line belonging to neither, and ran the VIP check on the merged value | `should_keep_each_message_distinct_when_two_share_an_id` |
| non-object `.events` elements | counted by `EVENTS_TODAY`, filtered out of everything else, so the counters stopped reconciling with nothing said | `should_count_an_unparseable_event_when_an_element_is_not_an_object` |
| all-day decided by the *text shape* of `startLocal` | **C11 straight back**: an all-day event whose `startLocal` carried an offset overlapped everything that day; and a timed event whose `startLocal` was a bare date vanished from the report entirely | `should_recognise_an_all_day_event_when_its_local_timestamp_carries_an_offset`, `should_keep_a_timed_event_when_its_local_timestamp_is_a_bare_date` |
| `prev_end_epoch=0` as the no-previous sentinel | 0 is a real end time, so events ending before 1970 never overlapped anything | `should_detect_a_conflict_when_both_events_end_before_the_epoch` |

Two of these are worth naming for what they say about the fix itself. The `.id` cluster is
one root cause: everything the fixtures fed through `.subject`, `.from` and `.summary` was
hardened, and `.id` — the one remaining attacker-influenced value — was passed to `grep`
unprefixed and used as a lookup key. And the all-day regression is the sharpest lesson
available: `start.date` was sitting in the same jq expression, and the code chose to infer
from a rendered string instead. The authoritative signal is now what decides.

## Mutation-checked

`mutation-check` changes one behaviour at a time in a copy of `hermes-check` and asserts
that at least one case notices.

```bash
.specs/005-hermes-check-correctness/tests/mutation-check [name-substring]
```

The first pass left five of 28 mutations uncaught. Three were real holes, now closed — each
of them a case that did not exist until the mutation asked for it:

| Uncaught mutation | What it revealed | Case added |
|---|---|---|
| the sender address is not lowercased | only the *entry* was folded, so an address written in capitals never matched | `should_flag_vip_when_the_sender_address_is_upper_case` |
| the sort key runs to the end of the line | a lexical key orders epochs of different digit widths wrongly — 9 digits sorts after 10 | `should_order_events_numerically_when_their_epochs_differ_in_width` |
| `gog`'s local timestamps are ignored | preferring `startLocal` is load-bearing: Google's `dateTime` + `timeZone` form carries no offset, so the fallback put a 09:00 New York meeting at 09:00 UTC | `should_use_the_offset_gog_supplies_when_a_timestamp_carries_none`, `should_apply_the_event_timezone_when_gog_supplies_no_offset`, `should_prefer_the_local_timestamp_when_nothing_else_carries_an_offset` |

That last one took two passes. Honouring `timeZone` in the fallback made the mutation
*equivalent again* — both paths then agreed — which is worth knowing rather than papering
over. The preference still earns its place for the shape where `timeZone` is absent too, and
for a container with no zone database: `TZ=America/New_York` silently falls back to UTC
without tzdata, while an explicit offset needs nothing installed. `calendar-gog-local-only.json`
is that case, and it is what finally catches the mutation.

Chasing the third also turned up a latent bug in the extraction itself: `read` with
`IFS=$'\t'` collapses a run of tabs and strips leading ones, so an event with no start would
have adopted its end as its start. Every field is now sentinelled, and
`should_count_an_unparseable_event_when_it_has_no_start_at_all` holds it.

All 37 mutations are caught, and `mutation-check` also fails loudly if an anchor stops
matching exactly once — which it did, twice, when a variable was renamed under one and when
a block it anchored on was rewritten.

A later pass, after the review fixes landed, left two more uncaught — and those two were the
most useful of the lot. All-day exclusion had ended up with **two independent mechanisms**:
the authoritative `start.date` flag from jq, and a bare-date glob in the shell. Each masked
the other, so neither could be shown to matter and a mutation to either passed unnoticed.
That is not defence in depth, it is two half-tested code paths. The glob is gone and `allday`
in jq now decides for every shape, in one place — at which point both mutations become
observable and both are caught. The other two are **deliberately absent** from `mutation-check`, because they have no
observable effect — which is the point of the structural fixes rather than a gap in the
cases:

- **Deriving `OTHER` by subtraction again.** With one bucket per message the counters are
  disjoint, so `new - urgent - vip` and the `other` counter agree for every input. C2 is
  unrepresentable, not merely fixed — the arithmetic that could disagree is gone.
- **Dropping the counter on the calendar-extraction failure path.** Every branch of the jq
  expression yields a string, so the extraction cannot fail on any shape that got past
  `fetch_json`. That path is there for the day something else does — jq missing, or killed —
  and it is unreachable from a fixture.

Both are named here rather than left out silently: a reader who wonders why the obvious
mutation is missing deserves the answer, and if either ever *becomes* observable this note is
where the mistake will show.

## Linting

Clean under `shellcheck -x -s bash`, which `lint-test` asserts over the whole directory
along with `hermes-check` itself. The suites carry `# shellcheck source-path=SCRIPTDIR` so
`-x` resolves `harness.sh` from any working directory.
