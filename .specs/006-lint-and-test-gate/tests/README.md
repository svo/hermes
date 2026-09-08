# 006 checks

Verification for [SPEC.md](../SPEC.md). These test the gate; the gate tests the repository.

```bash
bin/test                                        # the gate itself
.specs/006-lint-and-test-gate/tests/run         # just this spec's cases
```

No credentials, no network, no Google account. Every case works on a sandbox copy of the tree
under `mktemp -d`; nothing here writes to the working tree, and `config-schema-check` asserts
that it left the real `$HOME` alone.

| File | What it is |
|---|---|
| `run` | Entry point for 006. Accumulates failures rather than stopping at the first. |
| `harness.sh` | Shared assertions, the sandbox builder, and `run_gate`. Sourced, not run. |
| `discovery-test` | Which files the gate lints — the extensionless ones especially. |
| `accumulation-test` | One run reveals every problem, not the first one. |
| `red-baseline-test` | The gate seen failing, against the pre-005 script out of git history. |
| `skip-path-test` | What a skip means, and that it is never mistaken for a pass. |
| `entrypoint-contract-test` | E1 — the image runs `./bin/test`, trailing `CMD` arguments and all. |
| `workflow-wiring-test` | That `needs: [lint]` gates the build and no secret reaches the lint job. |
| `config-schema-check` | D2 — the config the entrypoint writes, validated against the real schema. |
| `stub-openclaw` | Fake `openclaw`: seeds a config, answers the gateway probes, logs its argv. |
| `stub-gog` | Fake `gog`, so the entrypoint's credential path runs without a Google account. |

Fifty-seven cases: 7 in `discovery-test`, 7 in `accumulation-test`, 5 in `red-baseline-test`,
10 in `skip-path-test`, 10 in `entrypoint-contract-test`, 8 in `workflow-wiring-test`, and 10
in `config-schema-check`.

`config-schema-check` is not in `run`. `bin/test` invokes it directly as its `config-schema`
check, because it is a check *of the repository* — it validates what the entrypoint writes —
and only incidentally lives here. The other six are checks *of the gate*.

## The loop, and the guard that opens it

`bin/test` runs `run` as its `gate-tests` check, and every case in `run` invokes `bin/test`.
That is a cycle by construction. `HERMES_GATE_TEST` is what breaks it: `harness.sh` exports it,
so every `bin/test` these cases start sees it, and a `bin/test` that sees it skips `gate-tests`.

Recursion here would not present as a red build but as a CI job that never ends, which is far
harder to diagnose. So the guard is asserted —
`should_skip_the_gate_tests_when_hermes_gate_test_is_set` — rather than left to inspection.

## Red before green

PLAN.md task 1 asks for the gate to be *seen* to fail before it is trusted: "A gate that has
only ever passed is indistinguishable from one that checks nothing, which is exactly how
`bin/test` came to be missing."

It cannot be seen to fail on the current tree, because 005 already fixed the five findings
SPEC finding E4 names. Writing five fresh violations to knock down would prove only that
shellcheck works. So the baseline comes out of git history instead, the way
[005's tests/README.md](../../005-hermes-check-correctness/tests/README.md) § Red before green
points its suites at the old script: `red-baseline-test` restores the pre-005 `hermes-check`
from `6e8932a^` into a sandbox and asserts the gate goes red on it.

Against that file, `shellcheck -s bash`:

| Rule | Count | What it was |
|---|---|---|
| SC2086 | 2 | the unquoted account flag — C10, and a real design smell, not noise |
| SC2106 | 3 | `continue` inside `$(...)`, which is C4: shellcheck had been reporting it for as long as the file existed |
| **total** | **5** | |

Then the gate over the same tree: `FAIL shellcheck`, exit non-zero, the failing file named,
and — asserted separately — *no other check* newly failing, so the red is attributable to the
restored file rather than to the sandbox.

One nuance worth stating rather than glossing. E4 anchors the findings at
`hermes-check:38,112,123,150,151`. Those line numbers are from the file as it stood before
**001**, at `8fe9fba`; the baseline this suite uses is the file before **005**, at `2f0dfda`,
where 001's sanitiser has already shifted them to `108, 194, 206, 237, 238`. Same five
findings, same two rules, different lines. `2f0dfda` is the right baseline for *this* spec —
it is the tree 005 actually fixed — and the case counts findings and rules rather than line
numbers so it does not depend on which of the two you pick.

The one thing this cannot survive is a checkout with no history. On a shallow clone the commit
is absent, and the case says so and skips rather than inventing a pass — which is why
`.github/workflows/lint.yml` checks out with `fetch-depth: 0` and hands the container
`safe.directory` for the mount. Without either, all five of these cases skip in CI, and the
only thing that ever *watches* the gate fail would be watching nothing.

## What the checks found that the spec did not

**The gate failed on its first honest run, and it was right to.**

`config-schema-check` runs the real `entrypoint.sh` against a stub and hands the configuration
it writes to the real `openclaw config validate`. The first time that ran end to end:

```
× openclaw.json:56 — tools.loopDetection: Unrecognized keys:
    "warningThreshold", "criticalThreshold", "globalCircuitBreakerThreshold"
```

Those three keys were added in `6585464` ("Prevent heartbeat tool-call loops with
isolatedSession and loopDetection"). They are valid nowhere in OpenClaw 2026.9.2's schema —
searched the whole 2.3 MB of `openclaw config schema`; `tools.loopDetection` accepts `enabled`
and nothing else, under `additionalProperties: false`.

This was not cosmetic. `entrypoint.sh` phase 3 runs `openclaw config validate` and **exits 1**
when it fails, and at the time the openclaw role installed `state: latest`, so the break arrived
with the next image build rather than with any change to this repository. A service image built
that day would have refused to start, printing a schema error about a key nobody had touched in
months. (007 has since pinned `openclaw_version`, so the arrival is now a reviewed bump rather
than a Thursday — which changes when this gate earns its keep, not whether it does.)

That is SPEC finding D2, and it is precisely the third user story — "I want config schema
violations caught at build time, so that an upstream rename fails a pipeline instead of every
running container." The gate caught it before a pipeline did. The fix is in `entrypoint.sh`:
`enabled: true` and nothing else, so loop detection stays on at upstream's defaults.

The key list in `config-schema-check` is what made removing them a *stated* change rather than
a silent one, and it is what will notice if they ever come back.

**Two more, found by running the gate the way CI runs it** — inside the published builder
image rather than on a developer machine. Both had the same shape: a check that passes
everywhere it was tried and fails in the one place it matters.

| Found | What it was | Fixed by |
|---|---|---|
| `bin/test` failed its `hermes-check` check on every CI run | `bin/hermes-check-test` refuses to start without `jq`, and no builder role installed it. `matrix` waits on `needs: [lint]` in all three workflows, so nothing could build — and `builder.yml` could not publish a fixed builder either, because its own build waits on the same gate. | `roles/jq`, wired into `playbook-builder.yml` |
| three of 005's classification cases failed in the builder image | `hermes-check` gates the urgency classifier on `[ -f /opt/hermes/urgency.bin ]`, so stubbing `fasttext` on `PATH` was never enough. The 800 MB model is provisioned on a developer machine and absent from the builder, so the suites silently depended on a file they never mentioned. | `MODEL_FILE` is now `${HERMES_MODEL_FILE:-...}`, and 005's `harness.sh` points it at an empty stub |

The second is worth naming for what it says about hermetic tests. 005's `stub-fasttext` carries
the comment "the real model is 800 MB … present on a developer machine and absent in CI" — the
dependency was *known* and the stub still only replaced the binary, because the file test sat
in a different part of the script from the call it guarded. Stubbing the executable and leaving
the existence check unstubbed is the kind of half-measure that passes every local run.

## What these checks do not cover

Named here rather than left for a reader to discover, because an unstated gap is the same
shape of problem as an unstated skip.

- **The container smoke test does not run in the Vagrant development box.** `/vagrant` is a
  virtiofs mount from a Lima VM while the Docker socket is forwarded from another; a bind
  mount of the repository arrives in the container empty. `bin/test` detects exactly that and
  skips with the reason, rather than reporting a failure it cannot attribute. It skips in CI
  too, for a different and deliberate reason: CI runs `bin/test` *inside* the builder
  container, and `lint.yml` withholds the Docker socket, because mounting it would hand
  pull-request-authored code root on the runner. So the check has no daemon anywhere it
  currently runs.
  What covers E1 in CI is the `lint` job one level up — its only step is a `docker run` of the
  image with no `--entrypoint`, so an image that lost its `ENTRYPOINT` fails the job instead of
  passing it. `entrypoint-contract-test` covers the rest statically: what `builder.pkr.hcl`
  declares, that `bin/test` exists and is executable, and that it tolerates the `CMD` arguments
  docker appends — none of which needs a daemon.
- **`ansible-lint` cannot see a pipe written as `shell: {cmd: ...}`.** `risky-shell-pipe`
  inspects only the free-form `shell: <string>` form. Both of this repository's pipes used the
  mapping form, so the rule PLAN.md task 2 expected to fire never did. Both pipes are gone now
  — deleted rather than guarded — but the blind spot is a property of the linter, and nothing
  here would catch a third pipe reintroduced in the mapping form.
- **Nothing verifies the published image's `ENTRYPOINT` against the registry.** The cases read
  `builder.pkr.hcl`, which is the source of truth for what the *next* build produces. An image
  already on Docker Hub that lost its entrypoint would not be caught until the smoke test ran
  against it in CI.
- **`workflow-wiring-test` parses YAML; it does not run GitHub Actions.** It can prove
  `needs: [lint]` is present and that no caller passes secrets. It cannot prove GitHub
  schedules the jobs the way the file reads. PLAN.md § Testing Strategy asks for an
  injected-violation check on a scratch branch for that, which is a thing to do once, by hand,
  and not something a suite can assert.

## Linting

Clean under `shellcheck -x -P SCRIPTDIR -s bash` at default severity — the strictest level,
which includes the `info` findings SPEC Open Question 2 asks about. The tree was already clean
there once 005 landed, so committing to `warning` would have left the gate looser than the code
it guards.

`-P SCRIPTDIR` is the gate's own invocation and is load-bearing: it is what lets `-x` resolve a
sourced `harness.sh` relative to the sourcing file rather than to the caller's `$PWD`. The
suites here and in 005 also carry `# shellcheck source-path=SCRIPTDIR`, but 003's two suites do
not, and without `-P` they raise SC1091 depending on where the gate was run from.

`bin/test` discovers these files by shebang and lints them along with everything else, so the
checks are held to the standard they enforce.
