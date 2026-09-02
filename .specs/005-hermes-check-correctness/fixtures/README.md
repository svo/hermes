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

## Field names are not yet verified

The shapes here (`.messages[].id`, `.subject`, `.from`; `.events[].summary`, `.start`,
`.end`) are the ones `hermes-check` currently reads. They have **not** been checked against
a real `gog --json` response — that is
[005 task 1](../PLAN.md), and it is sequenced first precisely because finding C1 triggers
when `.from` is absent or named differently. Re-pin these fixtures to a captured response
before writing 005's logic tests, or the harness will encode the same assumption that
causes the bug.

## Consumers

- `.specs/001-sanitize-untrusted-content/tests/` — injection and fence cases (present).
- `bin/hermes-check-test` — 005's harness (not yet written). When it lands it supersedes
  the stubs under 001's `tests/`; point those cases at it rather than keeping two harnesses.
