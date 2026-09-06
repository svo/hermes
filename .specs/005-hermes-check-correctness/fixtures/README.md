# hermes-check fixtures

Fixture responses for a stub `gog`, so `hermes-check` can be run end to end with no
credentials and no network.

They live here rather than under 001 because [001](../../001-sanitize-untrusted-content/SPEC.md)
creates them and [005](../SPEC.md) and [006](../../006-lint-and-test-gate/SPEC.md) reuse them
— one set, not three.

| Fixture | What it exercises |
|---|---|
| `gmail-forged-summary.json` | A subject that tries to close the report and open a fake `--- SUMMARY ---` |
| `gmail-control-characters.json` | CR, LF, TAB, VT, FF, BEL, ESC, DEL in a subject and a sender |
| `gmail-over-length-subject.json` | 300 ASCII characters, against the 200-character bound |
| `gmail-over-length-non-ascii.json` | 300 three-byte characters, so byte truncation would split one |
| `gmail-shell-metacharacters.json` | `$(id)`, backticks, `${HOME}`, `; rm -rf /`, pipes |
| `gmail-fence-forgery.json` | A subject containing the closing fence marker |
| `gmail-non-ascii.json` | Han, Cyrillic, combining accents, an em dash, an emoji |
| `gmail-line-separator.json` | `U+2028` / `U+2029`, which are not C0 controls |
| `gmail-clean.json` | Two ordinary messages — the baseline for `SANITIZED: 0` |
| `gmail-empty.json` | No messages |
| `calendar-clean.json` | One upcoming event |
| `calendar-conflict.json` | Two overlapping events — one real conflict |
| `calendar-newline-summary.json` | Overlapping events whose titles forge a conflict line and a count |
| `calendar-fence-forgery.json` | An event title containing the closing fence marker |
| `calendar-empty.json` | No events |
| `gmail-unparseable-from.json` | Two senders whose `From` carries no address at all |
| `gmail-missing-from.json` | `.from` absent entirely rather than unreadable |
| `gmail-vip-sender.json` | An ordinary sender, for pinning the VIP matching rule |
| `gmail-bare-array.json` | Valid JSON of the wrong shape — an array, not the envelope |
| `gmail-absent-key.json` | `{}` — an empty result, which must *not* read as an error |
| `gmail-not-json.html` | A zero exit with an HTML error page instead of a response |
| `calendar-unparseable-date.json` | One event whose dates cannot be read, one that can |
| `calendar-missing-end.json` | A readable start and an unreadable end |
| `calendar-all-day.json` | An all-day event beside two ordinary ones on the same day |
| `calendar-all-day-only.json` | Nothing but an all-day event — so there is no next event |
| `calendar-out-of-order.json` | A day listed latest-first, with one event spanning two others |
| `gmail-gog-shape.json` | A message as `gog` really emits it |
| `calendar-gog-shape.json` | Events as `gog` really emits them — `start`/`end` are objects |
| `calendar-gog-shape-conflict.json` | The same, overlapping, so the analysis is exercised too |
| `calendar-gog-no-local.json` | The bare Google resource, without gog's merged-in strings |
| `calendar-gog-timezone.json` | `dateTime` with no offset plus a separate `timeZone` |
| `calendar-gog-timezone-no-local.json` | The same, with gog's normalisation absent |
| `calendar-gog-local-only.json` | `dateTime` with neither an offset nor a `timeZone` |
| `calendar-epoch-width.json` | Events either side of the 10<sup>9</sup> epoch boundary |
| `calendar-missing-start.json` | An event with no start, but an end |
| `gmail-uppercase-sender.json` | An address written in capitals |
| `gmail-option-shaped-id.json` | An `id` of `-e`, which `grep` read as an option |
| `gmail-spoofed-display-name.json` | A display name impersonating a VIP's address |
| `gmail-vip-behind-decoy.json` | A real VIP with a decoy address in front of theirs |
| `gmail-missing-id.json` | A message with no `id` to track it by |
| `gmail-newline-id.json` | An `id` containing a newline |
| `gmail-duplicate-id.json` | Two messages sharing one `id` |
| `calendar-non-object-events.json` | `.events` elements that are not objects |
| `calendar-all-day-with-offset.json` | All-day, but with an offset-bearing `startLocal` |
| `calendar-timed-with-bare-local.json` | Timed, but with a bare-date `startLocal` |
| `calendar-pre-epoch.json` | Overlapping events that end before 1970 |

## Regenerating

`make-fixtures.py` writes every file in this directory. Run it and the fixtures must
come back byte for byte identical — it is how the escaping conventions below stay
consistent when a fixture is added or changed, not a second source of truth.

```bash
python3 .specs/005-hermes-check-correctness/fixtures/make-fixtures.py
git diff --exit-code .specs/005-hermes-check-correctness/fixtures/
```

## Conventions

- **Dates sit in 2099** so "next event" and "conflict" hold whenever the suite runs.
  `EVENTS_TODAY` counts what the fixture contains, not what is actually today.
- **Invisible characters are written as JSON escapes** (backslash-u-2028,
  backslash-u-0007), never as literals, so a payload is readable in a diff.
- **`NUL` is deliberately absent.** A bash variable cannot carry one, so it never reaches
  the sanitizer.

## Field names, verified

[005 task 1](../PLAN.md) was sequenced first so that the fixtures could not quietly agree
with the script. They have now been checked against the code that emits them
([steipete/gogcli](https://github.com/steipete/gogcli)), and one of the two shapes was
wrong.

**Gmail — correct as assumed.** `internal/cmd/gmail_messages.go` emits
`{"messages": [...], "nextPageToken": ...}`, each message carrying `id`, `threadId`, `date`,
`internalDateIso`, `from`, `subject` and `labels`. The three fields `hermes-check` reads are
real, and `from` and `subject` are flat strings — the CLI collapses `payload.headers` for
you. (Note `gog gmail search` is a *different* command over threads, emitting `threads`; the
script uses `gog gmail messages search`, which is the right one.)

**Calendar — not correct as assumed.** `internal/cmd/calendar_list.go` emits
`{"events": [...], "nextPageToken": ...}`, but each event is the **raw Google Calendar v3
Event resource**, with six string fields merged in by `internal/cmd/calendar_event_days.go`.
So `start` and `end` are **objects**, not strings:

```json
{ "start": { "dateTime": "2099-01-01T09:00:00+00:00" } }   // timed
{ "start": { "date": "2099-01-01" } }                      // all-day, end date EXCLUSIVE
```

`hermes-check` read `.start` as a string and handed the object to `@tsv`, which refuses one.
jq failed, the loop read nothing, and the report showed `EVENTS_TODAY: 2` beside
`NEXT_EVENT: none` and `CONFLICTS: 0` — every reminder and every clash dropped, with the
reason on stderr where nothing was reading. That is the failure this section exists to
prevent, and it was invisible to fixtures written from the script's own assumptions.

The `*-gog-shape*` fixtures are pinned to the real envelope. The older flat-string fixtures
are kept deliberately: the extraction still reads them, and they are the regression guard
that says so.

Still worth doing when an account is available: capture one live `gog gmail messages search
--json` and one live `gog calendar events primary --today --json`, and diff them against
these. Source-derived is better than assumed, but it is not the same as observed.

## Consumers

- `bin/hermes-check-test` — the harness. One entry point for every check on `hermes-check`.
- `.specs/005-hermes-check-correctness/tests/` — the correctness cases, and the stubs.
- `.specs/001-sanitize-untrusted-content/tests/` — injection and fence cases; they take
  their stubs from 005's `tests/` rather than keeping a second copy.
