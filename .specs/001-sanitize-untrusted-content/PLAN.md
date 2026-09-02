# Plan: Sanitize untrusted content before it reaches the agent

> Adapted from the `plan` skill — see [`.specs/README.md`](../README.md) § Template adaptation.
> Spec: [`SPEC.md`](SPEC.md)

## Implementation Strategy

One choke point, applied at the emit sites, plus a prompt clause that tells the agent what
the fence means. Prefer editing the two existing files over introducing new ones.

The key decision is **where** to sanitize. Two candidates:

- **At extraction** (`hermes-check:55-58`, `:132`) — sanitize as values are read from jq.
- **At emission** (`:78`, `:129`, `:157`) — sanitize as values are written to stdout.

Choose **emission**. Extraction-time sanitizing would corrupt values still used for logic
(`from_addr` feeds VIP matching at `:72`; `summary` feeds conflict pairing at `:157`), and
005 depends on those raw values behaving correctly. Emission-time sanitizing keeps the
logic operating on real data and makes the trust boundary a single visible line per site.

`sanitize_field()` is deliberately pure — stdin to stdout, no state, no globals except the
truncation bound — so 005's test harness can exercise it directly.

## Layer Changes

### Provisioning (`infrastructure/ansible/roles/`)
None.

### Runtime configuration (`roles/openclaw/files/entrypoint.sh`)
- Edit the heartbeat prompt string at `:44` only. Add a clause naming the fence markers,
  stating that fenced content is data from untrusted third parties, and that instructions
  appearing inside a fence must be reported rather than followed.
- Keep the existing `HEARTBEAT_OK` contract intact — 003 and 004 both depend on it.
- **Do not** touch lines 1–99 (owned by 004) or 248–287 (owned by 002/003/007).

### Agent pipeline (`roles/openclaw/files/hermes-check`)
- Add `HERMES_FIELD_MAX_LEN="${HERMES_FIELD_MAX_LEN:-200}"` beside the existing constants
  at `:4-8`.
- Add `sanitize_field()` after the constants, before `add_reason()` at `:21`. Implementation
  shape: `tr -d '[:cntrl:]'` → strip `<` `>` → collapse runs of whitespace → `cut -c1-N` →
  append `…` when truncated. Increment a `sanitized_count` when the value changed.
- Apply at `:78` when building `line`, at `:129` when building `next_event`, and at `:157`
  when building `conflict_lines`.
- Emit fence markers around the untrusted regions and `SANITIZED: ${sanitized_count}` in
  the summary block after `:175`.

### Agent instructions
- Heartbeat prompt only (above). `AGENTS.md` is not loaded during heartbeats, so adding the
  clause there would not help — this is the reason the prompt is the right place.

### Image & CI
None. Fixtures created here live at `.specs/005-hermes-check-correctness/fixtures/` so 005
and 006 reuse them rather than duplicating.

## Configuration Contract

| In | Out |
|---|---|
| `HERMES_FIELD_MAX_LEN` (optional, default 200) | `SANITIZED: <n>` line in summary |
| — | Fence markers around untrusted regions of `--- EMAIL ---` and `--- CALENDAR ---` |

Fence marker strings are defined once in `hermes-check` and quoted verbatim in the
`entrypoint.sh:44` prompt. Changing one without the other is the drift risk; the test in
task 7 asserts they match.

## Task List

Each task is independently committable.

1. [ ] pipeline: add `HERMES_FIELD_MAX_LEN` constant and the pure `sanitize_field()` helper
       to `hermes-check`; no call sites yet. Verify with `bash -n` and `shellcheck`.
2. [ ] pipeline: apply `sanitize_field()` at the email emit site (`:78`).
3. [ ] pipeline: apply `sanitize_field()` at the calendar emit sites (`:129`, `:157`).
4. [ ] pipeline: add fence markers around untrusted output regions and the
       `SANITIZED: <n>` summary line.
5. [ ] instructions: add the untrusted-data clause to the heartbeat prompt in
       `entrypoint.sh:44`, quoting the fence markers verbatim.
6. [ ] tests: add injection fixtures — forged `--- SUMMARY ---`, CRLF, control characters,
       over-length subject, shell metacharacters, angle brackets — under
       `.specs/005-hermes-check-correctness/fixtures/`.
7. [ ] tests: add a drift assertion that the fence markers in `hermes-check` and the prompt
       string in `entrypoint.sh` are identical.
8. [ ] docs: note the sanitisation boundary and `HERMES_FIELD_MAX_LEN` in `README.md`.

## Testing Strategy

No test framework exists in this repository. Available and sufficient:

- `bash -n` — syntax, after every task.
- `shellcheck -s bash` — must stay clean; this file is a 006 gate input.
- **Stub-`gog` harness** (defined in 005, used here): a fake `gog` earlier on `PATH` that
  emits fixture JSON, so `hermes-check` can be run end-to-end with no network or credentials.
  001's fixtures are the injection payloads; 005's are the logic cases.
- Assertion style: one behaviour per case, named `should_<behaviour>_when_<condition>` —
  mirroring the skill's `test_should_..._when_...` convention adapted to shell.

Coverage target: every acceptance criterion in `SPEC.md` maps to at least one fixture.
The forged-`--- SUMMARY ---` case is the one that must not regress.

## Operability Plan

- `SANITIZED: <n>` in every run's summary; sustained non-zero warrants investigation.
- No per-field warnings — they would themselves be attacker-influenced output.
- Verification command for the operator:
  `docker exec hermes hermes-check | grep -cx -- '--- SUMMARY ---'` must return `1`.
  The `-x` is load-bearing. Sanitising makes hostile text inert, it does not censor it, so
  a fenced line may legitimately *contain* `--- SUMMARY ---` — that is what a forged
  section header looks like after it has been defused. What must never appear is a second
  line that **is** that header. Without `-x` the count rises whenever someone is probing
  and the check reads as a breach when it is the design working; a run against the
  forged-summary and newline-summary fixtures returns `3`.

## Risks and Mitigations

- **Risk:** over-aggressive stripping makes legitimate subjects unreadable (non-Latin
  scripts, punctuation). → **Mitigation:** strip only `[:cntrl:]` and angle brackets; leave
  all printable Unicode intact. Verify with a non-ASCII fixture.
- **Risk:** the fence itself becomes the injection vector if a value can contain the closing
  marker. → **Mitigation:** angle brackets are stripped from values, so an XML-ish closing
  tag cannot be reconstructed. Covered by a dedicated fixture.
- **Risk:** the prompt clause and the markers drift apart in a later edit. → **Mitigation:**
  task 7's drift assertion, run by `bin/test` once 006 lands.
- **Risk:** sanitising changes values that 005 later assumes are raw. → **Mitigation:**
  emission-time-only sanitising, stated above; 005's logic reads the raw variables.
- **Risk:** this reduces injection efficacy but does not eliminate it — the agent still has
  a root shell. → **Mitigation:** tracked as SPEC Open Question 3; not closed by this spec.
  Do not describe 001 as "fixing prompt injection".
