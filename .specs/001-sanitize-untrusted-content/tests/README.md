# 001 checks

Verification for [SPEC.md](../SPEC.md). No credentials, no network, no Google account —
a stub `gog` on `PATH` serves fixture JSON instead.

```bash
.specs/001-sanitize-untrusted-content/tests/run
```

| File | What it is |
|---|---|
| `run` | Entry point. Runs every check, accumulating failures rather than stopping at the first. |
| `harness.sh` | Shared assertions and the hermetic runner. Sourced, not run. |
| `sanitize-unit-test` | `sanitize_field()` on its own, lifted out of the script. |
| `sanitize-injection-test` | `hermes-check` end to end against attacker-shaped fixtures. |
| `fence-drift-test` | The fence markers in `hermes-check` and in the heartbeat prompt are the same strings. |
| `stub-gog` | Fake `gog`: prints a fixture, exits with a chosen status. |
| `stub-fasttext` | Fake urgency classifier, so bucket assignment is identical everywhere. |

Fixtures live in [`../../005-hermes-check-correctness/fixtures/`](../../005-hermes-check-correctness/fixtures/README.md)
so that 005 and 006 reuse them rather than duplicating.

## Why the stubs are here

005's `PLAN.md` owns the real harness (`bin/hermes-check-test`), and 001's plan assumes it.
It does not exist yet, and without it none of 001's acceptance criteria is verifiable. These
are the smallest stubs that close that gap, and they follow the environment contract 005
describes (`GOG_FIXTURE`, `GOG_FIXTURE_EXIT`), widened so one run can serve both the gmail
and the calendar call.

**When 005 lands, point these cases at `bin/hermes-check-test` and delete the stubs.** Two
harnesses would drift.

`stub-fasttext` is not part of that contract. It exists because `/opt/hermes/urgency.bin` is
present on a developer machine and absent in CI, so without it the same fixture lands in a
different bucket in each place.

## Red before green

Every case here was run against the pre-change files first. Against the original
`hermes-check`, 17 of 22 injection cases fail; against the original `entrypoint.sh`, 2 of 6
drift cases fail. To repeat that:

```bash
HERMES_CHECK=/path/to/old/hermes-check .specs/001-sanitize-untrusted-content/tests/sanitize-injection-test
ENTRYPOINT=/path/to/old/entrypoint.sh  .specs/001-sanitize-untrusted-content/tests/fence-drift-test
```

Five injection cases pass against the original. That is correct, and worth knowing:

- The calendar path already routed titles through `jq @tsv`, which escapes newlines. That is
  finding A1c — the email path is the one that bypassed it. Those cases are regression
  guards, and they matter because 005 rewrites the calendar loops.
- Shell metacharacters were never substituted; a variable assigned from a command
  substitution is not re-evaluated. The case pins that so it stays true.
- The long non-Latin subject was never truncated at all before the bound existed, so there
  was no codepoint to split.

## Mutation-checked

Each case was also shown to be sensitive: a copy of the implementation was mutated one
behaviour at a time — angle-bracket strip, control-character delete, truncation, the UTF-8
tail-strip, each fence emission, the `SANITIZED` counter and its increment, the numeric
guard, the U+2028 fold, and each of the two titles quoted in a conflict line — and in every
case the suite failed on the case that names that behaviour. The conflict-line coverage
(`calendar-conflict-forgery.json`) exists *because* that pass initially found nothing
failing when the carried title stopped being sanitized.

## Linting

Clean under `shellcheck -x -s bash`, and clean without `-x` when `harness.sh` is among the
inputs — which is what a whole-tree lint does. Linting a single suite file on its own
without `-x` reports SC1091 (info) for the unfollowed `source`; the suites carry
`# shellcheck source-path=SCRIPTDIR` so `-x` resolves it from any working directory.

## Coverage

Every acceptance criterion in `SPEC.md` maps to at least one case. The forged
`--- SUMMARY ---` case is the one that must not regress.
