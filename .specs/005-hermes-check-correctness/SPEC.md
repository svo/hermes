# Feature: hermes-check correctness

> Adapted from the `specify` skill — see [`.specs/README.md`](../README.md) § Template adaptation.

## Overview

`hermes-check` is the pre-processing pipeline the agent runs on every heartbeat. It decides
`ACTION_NEEDED`, which decides whether the user is notified. The monitoring is the product,
and it has five reproducible defects — every one confirmed by running the code:

- An unparseable `From` header makes **every unread message a VIP**, because an empty
  pattern matches every line in the VIP file.
- `OTHER` goes **negative** when a message is both urgent and VIP.
- A malformed `gog` response kills the script with **exit 4 and no output at all**.
- `|| continue` inside a command substitution does not skip the iteration, so events with
  unparseable dates silently vanish from conflict detection.
- VIP domain matching is reversed, so `example.com` matches a VIP entry of `notexample.com`.

Two further issues: the unquoted `$gog_account_flag` is load-bearing and the obvious
shellcheck "fix" would break it, and all-day calendar events produce spurious conflicts.

## Source Findings

| ID | Claim | Anchor | Confidence |
|---|---|---|---|
| C1 | Empty `from_addr` → `grep -qiF ""` matches every line → all messages VIP | `hermes-check:72` | execution-verified |
| C2 | `new_count - urgent_count - vip_count` double-subtracts overlaps → prints `OTHER: -1` | `hermes-check:100`, `:67`, `:74`, `:79-82` | execution-verified |
| C3 | Unguarded `jq` in a substitution under `set -euo pipefail` → exit 4, no output | `hermes-check:39` | execution-verified |
| C3b | The `\|\| echo '{"messages":[]}'` guard fires only on non-zero exit, not on valid-exit non-JSON | `hermes-check:38` | execution-verified |
| C4 | `\|\| continue` inside `$( )` does not skip the iteration (SC2106 ×3) | `hermes-check:123`, `:150`, `:151` | execution-verified |
| C5 | Reversed substring containment in VIP domain matching | `hermes-check:72` | execution-verified |
| C10 | Unquoted `$gog_account_flag` is load-bearing; quoting it passes an empty argument | `hermes-check:38`, `:112` | execution-verified |
| C11 | All-day events (date-only start, exclusive end) produce spurious conflicts; `sort -k2` sorts to end-of-line | `hermes-check:164` | internal-contradiction |

## User Stories

- As the user, I want VIP to mean VIP, so that a flagged message is worth my attention.
- As the user, I want counts that add up, so that the summary is trustworthy.
- As the operator, I want a failed upstream call to produce a diagnosable message rather
  than silence, so that broken monitoring is distinguishable from a quiet inbox.
- As the operator, I want calendar events with odd dates to be reported as unparseable
  rather than silently dropped.
- As the maintainer, I want the script to be testable without Google credentials, so that
  these bugs are caught before they ship.

## Acceptance Criteria

- [ ] Given a message whose `From` yields no parseable address, when the VIP check runs,
      then it is **not** flagged VIP.
- [ ] Given an empty `vip-senders.txt`, when any message is checked, then no message is VIP.
- [ ] Given sender domain `example.com` and a VIP entry `notexample.com`, when checked, then
      it is **not** VIP.
- [ ] Given sender `bob@example.com` and a VIP entry `example.com`, when checked, then it
      **is** VIP.
- [ ] Given a message that is both urgent and VIP, when the summary is emitted, then
      `URGENT + VIP + OTHER == NEW_UNREAD` and `OTHER >= 0`.
- [ ] Given `gog` exits zero with non-JSON output, when `hermes-check` runs, then it emits a
      complete report including a `--- SUMMARY ---` section and a named data-source error.
- [ ] Given `gog` exits non-zero, when `hermes-check` runs, then the same holds.
- [ ] Given a calendar event with an unparseable date, when the script runs, then it is
      counted in an `UNPARSEABLE_EVENTS` line and excluded from conflicts — not silently
      dropped, and no `integer expression expected` reaches stderr.
- [ ] Given `GOG_GOOGLE_ACCOUNT` is unset, when `gog` is invoked, then no empty argument is
      passed.
- [ ] Given an all-day event, when conflict detection runs, then it does not produce a
      conflict against every other event that day.
- [ ] Given `shellcheck -s bash hermes-check`, then it exits zero.
- [ ] Given the stub-`gog` harness, then every criterion above is exercised without network
      access or credentials.

## Structural Impact

### Provisioning
No change.

### Runtime configuration
No change. `hermes-check` is installed by `roles/openclaw/tasks/main.yml:29-34`; the copy
task is unchanged.

### Agent pipeline (`roles/openclaw/files/hermes-check`)
Owned region: VIP matching, counters, jq guards, date parsing. `sanitize_field()` and the
emit sites belong to **001**.

- `:71-76` — VIP matching: require a non-empty needle; match whole lines with correct
  containment direction.
- `:60-85`, `:100` — classification: one bucket per message; derive `OTHER` by counting, not
  by subtraction.
- `:38-39`, `:55-56`, `:112-113` — data acquisition: validate JSON before use; report a
  named error instead of aborting.
- `:121-132`, `:148-164` — date handling: replace `|| continue` with a guard in the loop
  body; count unparseable events; handle all-day events.
- `:13-16`, `:38`, `:112` — replace the string flag with an array.

### Agent instructions
- `AGENTS.md` — document that a VIP entry matches an exact address or a domain suffix, since
  the current text implies behaviour the code does not have.

### Image & CI
- The stub-`gog` harness and fixtures land here and are consumed by **006**.

## Configuration Contract

No new environment variables. New output lines:

| Line | Meaning |
|---|---|
| `DATA_SOURCE_ERRORS: <n>` | upstream calls that failed or returned unusable data |
| `UNPARSEABLE_EVENTS: <n>` | calendar events excluded due to unreadable dates |

Both are additive. `ACTION_NEEDED` is set when either is non-zero — broken monitoring is
itself actionable.

## Operability

- The script always emits a complete report, including `--- SUMMARY ---`, even when every
  upstream call fails. Silence is never a valid output.
- The invariant `URGENT + VIP + OTHER == NEW_UNREAD` is assertable by the operator directly
  from the output.

## Dependencies

- **Depends on 001** — consumes `sanitize_field()`; do not re-implement it.
- **Blocks 006** — the lint gate cannot pass until SC2086 and SC2106 are resolved here.

## Open Questions

1. **VIP match semantics.** Exact address, or domain-suffix match (`@example.com` and any
   subdomain)? Suffix matching is what users expect from "one email or domain per line" but
   needs a stated rule for subdomains. Recommendation: exact address match, or exact domain
   match after `@`. Confirm before implementing.
2. **`gog` JSON field names.** `.messages[].id`, `.subject`, `.from`, `.events[].start`
   are assumed and unverified. C1 triggers precisely when `.from` is absent or differently
   named. **Capture one real `gog ... --json` response and pin the fixtures to it** before
   writing the tests, or the harness will encode the same assumption.
3. **All-day events.** Exclude from conflict detection, or treat as background context that
   never conflicts? Recommendation: exclude, and report them separately.
4. **The urgency model.** 327 training lines of SRE-incident text, subject-only, no
   confidence threshold, gating `ACTION_NEEDED`. Out of scope here, but the classifier is
   the weakest link in the chain this spec is repairing. Track as its own spec?
