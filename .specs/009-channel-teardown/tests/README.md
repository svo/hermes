# 009 checks

Verification for [SPEC.md](../SPEC.md) and [PLAN.md](../PLAN.md). No image, no credentials, no
Anthropic key: the real `entrypoint.sh` runs against stub `openclaw` and `gog` binaries.

```bash
.specs/009-channel-teardown/tests/run
```

| File | What it is |
|---|---|
| `run` | Entry point. Runs every check, accumulating failures rather than stopping at the first. |
| `harness.sh` | Shared assertions and the hermetic runner. Sourced, not run. 008's, plus `config_text`, `home_files_holding` and `patch_count`. |
| `teardown-test` | All six acceptance criteria, plus idempotence, the surviving allowlist, whose channel block it is, and a teardown that fails closed. |
| `schema-check` | The probe, kept: a torn-down config handed to a **real** `openclaw config validate`. Skips without one on PATH. |
| `mutation-check` | Sensitivity check. Not part of `run`; see below. |
| `stub-openclaw` | Fake `openclaw`: `onboard`, `gateway`, `gateway health`, `config patch`, `config set`, `config get`, `config validate`, `doctor`, `automations list`. |
| `stub-gog` | Fake `gog`. Records and succeeds. |

Thirty-five cases: 32 in `teardown-test`, 3 in `schema-check`. The three skip when no real
`openclaw` is on PATH, and say so.

## Every case is a restart

A container has to be started **with** a token before a start **without** one means anything, and
a single start can never tell you which way it went. So almost every case here runs the entrypoint
twice over one `--home`, which is 008's mechanism used for the thing it turns out to be for.

The red baseline is the pre-009 entrypoint: **21 of the 32 fail against it**, and the 11 that pass
are the ones that assert nothing happens — criteria 4 and 5, which the old entrypoint satisfied by
never doing anything at all, and the ownership cases, which are about channels it was never going
to touch either. That split is the shape of the finding.

## The probe came first, and `schema-check` is it, kept

Both of `SPEC.md`'s Open Questions turned on one thing: whether a channel block that has had its
token deleted is still a *legal* channel block. If `botToken` were required, "disable and strip the
token" would produce a config the phase 3 gate refuses — an operator would remove a token and get a
container that will not start, which is worse than the bug being fixed.

Run against `openclaw@2026.9.2`, the version `roles/openclaw/defaults/main.yml` pins:

```
channels.telegram  required: ["dmPolicy","groupPolicy"]
channels.slack     required: ["dmPolicy","groupPolicy","postAs","mode",
                              "webhookPath","userTokenReadOnly"]
```

Neither names a credential. `PLAN.md` § The probe, first records it in full. `schema-check` is
that probe turned into a case, so an upstream release which makes a credential required goes red
here rather than in a running container.

## Three things the probe found that the spec did not raise

**An unguarded teardown creates the empty block criterion 5 forbids.** Patching
`{enabled: false, botToken: null}` against a container that never configured Telegram leaves
`{"telegram":{"enabled":false}}` behind — and `openclaw config validate` **accepts** it. So nothing
downstream catches it, and the guard's "is this channel actually in the persisted config" clause is
what stands in the way. It has its own cases and its own mutation — and the mutation had to be
rewritten once, because after clause 3 was narrowed the original mutant became correct rather than
broken. See § Mutations.

**`config patch` cannot make the teardown a one-off.** It counts the paths in the payload rather
than the paths that changed, so re-applying a finished teardown answers `Applied 2 config
update(s)` and exits zero, for ever. Without the guard's third clause the teardown line would print
on every start for the rest of the volume's life. `should_tear_down_once_when_the_container_
restarts_again` counts the patches rather than reading the config, because a volume torn down last
start looks exactly like one being torn down now.

**`config get` reports the effective config, not the authored one.** It merges runtime defaults in
— `groupPolicy` comes back for a Telegram block that never authored one. A guard built on it would
see defaults where it has to see what is persisted, which is wrong in the direction that matters.
The planner reads the authored file, and a mutation points it elsewhere to prove a case notices.

## What the stub does that a convenient stub would not

It is 008's stub with three changes. The first two are forced by the same fact — **this entrypoint
now patches twice** on a start that tears a channel down — and the third by what those patches
leave behind.

**It records patch documents one per line instead of overwriting.** 008's stub kept the last
document, which was the only one. Overwriting now would leave the suite unable to tell one patch
from two — and "did the teardown happen" is a question about the second one, which the config
cannot answer.

**Its rejection can be aimed.** `OPENCLAW_STUB_PATCH_ERROR_MATCH` fires the error only for a
payload containing a given substring. Without it, a case that wanted to see a rejected *teardown*
would also reject 008's configuration patch and kill the start in phase 2, long before reaching the
block under test.

**It writes the backups the real setter writes.** `openclaw config patch` copies the old
configuration to `openclaw.json.bak` before writing the new one and rotates five generations,
`.bak` through `.bak.4` — probed against the pinned CLI. 009 sweeps those files because on a
teardown they hold a credential the operator revoked, and a stub that skipped them would let that
sweep be deleted with the suite still green. It did, until the stub learned this.

Everything else is 008's, including the strictness about flags that 008's `mutation-check` proved
load-bearing. `the teardown is only ever a dry run` is caught here for the same reason it was
there: the stub refuses a flag it does not model.

## Mutations

```bash
.specs/009-channel-teardown/tests/mutation-check
```

Twenty-four mutations, one behaviour each, all against a copy of `entrypoint.sh`. Every one is
caught. It is not part of `run` because it re-runs the suite up to twenty-four times.

Each mutation asserts its anchor occurs exactly once in the file, and that the mutant still parses
as bash, before it is applied; a bad anchor is reported as a bad anchor rather than as a caught or
uncaught mutation.

**Five of them found holes rather than confirming patches**, and three of those came from an
adversarial review run after the suite was already green.

**`the setter backups keep the revoked token`** and **`only the newest backup is swept`** are the
serious pair. `openclaw config patch` copies the old configuration to `openclaw.json.bak` before
writing, and rotates five generations. So the command that removes a revoked token from the config
writes it into a file beside the config — `openclaw.json` clean, volume dirty, and acceptance
criterion 2 (which names *`openclaw.json`*) satisfied over the top of the user story it exists to
serve. Three things changed: the teardown sweeps `openclaw.json.bak*`, criterion 2 is asserted
against **every file under `$HOME`**, and the stub writes and rotates backups the way the real CLI
does. That last one is not decoration — with a stub that wrote no backups, both mutations survived
even after the sweep was in place, because there was nothing for a missing sweep to leave behind.

**`a channel this container never configured is torn down`** is the guard's third clause as it was
first written: "still enabled, **or** still holding a credential". An operator who configures
Telegram themselves with `tokenFile` — a key this container never writes — had their working
channel disabled and was told a token had been removed that nothing here ever touched. The clause
is now "still holds one of **our** credentials", which is smaller and covers every case the
criteria name.

**`the guard inspects a channel that is not in the config`** replaced a mutation that had become
*correct*. It used to soften clause 2 to `channels[name] || {}`; once clause 3 was narrowed to
"still holds one of our credentials", an empty object holds no credential and is skipped — so the
mutant behaved properly and the mutation proved nothing. It survived a full run and was rewritten
to drop the guard outright, which is the real regression: `hasOwnProperty.call` throws on
`undefined`, so the planner aborts on every container that configures one channel and not the
other. A narrowed guard making a neighbouring mutation vacuous is not obvious, and it is the reason
this file is run again after any change to the block rather than only when a case is added.

**`the teardown is written straight to the file`** was *vacuous* in its first form: the replacement
read `process.env.PAYLOAD` without setting it, so the mutant threw on `JSON.parse(undefined)` and
was reported caught for having crashed rather than for having bypassed the setter. It now hands the
payload over in the environment and genuinely performs the teardown by hand — and
`should_tear_down_through_the_setter_when_a_channel_goes` catches it by counting patches, which is
the right reason.

**One more found a hole in the first draft.** `the teardown is announced before it
happens` moves the log lines above the write, and the first draft of this suite did not catch it:
`should_refuse_to_start_when_the_teardown_is_rejected` asserted the failure and forgot the silence.
Announced first, the line survives a patch that was refused — the operator reads that a channel was
disabled and its token removed while both are exactly as they were, which is worse than saying
nothing because it is the line they would have checked. This is the same shape 008 found in its own
approvals block, where the exit code was reported instead of the outcome.
`should_not_claim_a_teardown_when_the_patch_is_rejected` exists because of that mutation.

Three others are worth knowing about:

- **`slack keeps its app token`** is the asymmetry `SPEC.md` § Overview says neither 002 nor 004
  could fix half of, in its most plausible form: Slack tidied up as if it were Telegram, leaving an
  app-level token with `connections:write` behind.
- **`a channel block is created on a container that never configured one`** is the probe's finding
  as a mutation. Nothing downstream would catch it, because the empty block validates.
- **`a hand-disabled channel keeps its token`** weakens the guard's third clause from "still enabled
  **or** still holding a credential" to "still enabled". An operator who set `enabled: false` by
  hand and left the token in the file has done half a teardown; the half that matters is the other
  one.

## Why this suite is not a `bin/test` check

It is not wired into the gate, and that follows the precedent rather than overlooking it: 002's,
003's, 004's, 007's and 008's suites are entrypoint suites too, and none of them is a `bin/test`
check either.
[`008/tests/README.md`](../../008-config-via-cli/tests/README.md) § *Why this suite is not a
`bin/test` check* gives the cost in full, and it applies here unchanged.

What the gate does still do is lint these files: discovery finds scripts by shebang rather than by
extension, so `run`, `harness.sh`, both stubs, both suites and `mutation-check` go through `bash -n`
and `shellcheck -x -P SCRIPTDIR -s bash` on every CI run.

## What is not covered here

- **The planner failing outright.** The entrypoint refuses to start if it cannot ask the config
  which channels are configured, on the grounds that a container which cannot tell may still be
  holding a revoked credential. No case drives it: the planner swallows an unreadable or
  unparseable config as "nothing to tear down" — which is correct on a first-ever start — so the
  only way to the failing branch is a `node` that will not run, and standing up a broken `node` on
  PATH would break far more than the branch under test. It is belt-and-braces behind `set -e`,
  which would kill the start anyway, and it is named here rather than left to look tested.
- **A disabled channel actually not answering.** `enabled: false` is upstream's switch, and what
  the gateway does with it needs a running gateway and a real Slack or Telegram workspace. What is
  asserted here is that the config says so and that the config is legal.
- **`commands.ownerAllowFrom` after the last channel goes.** It keeps naming an identity on a
  channel that no longer answers. Recorded in `PLAN.md` § Findings This Work Added as B3d-a, and
  deliberately not fixed: those entries are user IDs rather than credentials, no acceptance
  criterion covers them, and the behaviour is 008's recursive merge rather than this block's.
