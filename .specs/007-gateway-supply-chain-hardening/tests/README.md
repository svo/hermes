# 007 checks

Verification for [SPEC.md](../SPEC.md). No image, no credentials, no Anthropic key: the real
`entrypoint.sh` runs against stub `openclaw` and `gog` binaries, and the roles are read as YAML.

```bash
.specs/007-gateway-supply-chain-hardening/tests/run
```

| File | What it is |
|---|---|
| `run` | Entry point. Runs every check, accumulating failures rather than stopping at the first. |
| `harness.sh` | Shared assertions and the hermetic runner. Sourced, not run. |
| `bind-test` | Track 1 — where the gateway listens, the token that guards a non-loopback bind, and what the startup line says. |
| `provisioning-test` | Track 2 — the pins, the digests, and the build-time lookup that is gone. |
| `stub-openclaw` | Fake `openclaw`: `onboard`, `gateway`, `gateway health`, `config get`, `config validate`, `automations list`. |
| `stub-gog` | Fake `gog`. Records and succeeds. |

Forty-nine cases: 34 in `bind-test`, 15 in `provisioning-test`; one skips unless
`HERMES_CHECK_UPSTREAM=1`. Track 3 adds `permissions-test` and `mutation-check` on top.

## Why this suite is not a `bin/test` check

It is not wired into the gate, and that follows the precedent rather than overlooking it: 002's,
003's and 004's suites are entrypoint suites too, and none of them is a `bin/test` check either.
Only `bin/hermes-check-test` (005 and 001), 006's `config-schema-check` and 006's own `run` are.

There is a specific cost to adding one here. 006's cases test the gate by building a disposable
copy of the whole repository and running `bin/test` over it, dozens of times — so a new check
would run this entire suite inside every one of those sandboxes, and `red-baseline-test` asserts
that exactly one check goes red in a damaged tree. A new way to go red inside that assertion is
not a change to make casually as part of another spec.

What the gate does still do here is lint these files: discovery finds scripts by shebang rather
than by extension, so `run`, `harness.sh`, both stubs, all three suites and `mutation-check` go
through `bash -n` and `shellcheck -x -P SCRIPTDIR -s bash` on every CI run.

**If you would rather have it in CI**, the change is one `check` call in `bin/test` next to the
`config-schema` one, plus a re-run of 006's suite to confirm the sandbox timings and the
red-baseline count still hold.

## Why not a container

`PLAN.md` § Testing Strategy specifies container-level verification — `docker exec hermes
openclaw config get gateway.bind`, `openclaw gateway status`, `stat -c '%a'` on the persisted
config, a real gateway refusing a real unauthenticated bind. That needs the image and an
Anthropic API key, so it is not something a check can do on its own.

These cases assert the same behaviour by a shorter route. The entrypoint is the thing under test
either way; only `openclaw` and `gog` are replaced. Each run gets a private `HOME` and an
`env -i` environment carrying just the variables the case wants, so no persisted config or
ambient variable carries between cases. Two findings are only visible across runs — the
persisted `bind: lan` an upgrading container carries, and the `0644` config an older image left
behind — so those cases hand the same `HOME` to several runs.

## What the stubs do that a convenient stub would not

**Onboarding honours the flags.** 004's stub hardcodes `bind: 'lan'` and ignores argv entirely,
which is fine for what 004 tests and useless here: the whole of track 1 is about which value
reaches which flag. This stub parses `--gateway-port` and `--gateway-bind` and writes what it was
told, so a case can tell "the entrypoint sent loopback" from "the stub always says loopback".

**Onboarding generates a token.** Upstream documents onboarding as using token auth by default
and generating a token when no stored or explicit credential applies, so the stub writes one. A
stub that onboarded with no auth would model a container that has never existed — and it would
quietly turn `should_leave_an_onboarding_token_alone_when_the_bind_is_loopback` green by giving
it nothing to leave alone. `OPENCLAW_STUB_ONBOARD_AUTH=none` and `=bare` drive the other two
shapes.

**Every invocation is logged, one record per write.** The config records the bind, but only argv
records that `exec openclaw gateway` was told the same thing — and the two disagreeing is finding
A3a.

The single-write part is load-bearing rather than tidy. Two processes append to that log
concurrently — the foreground `exec openclaw gateway`, and 003's briefing registrar probing
`openclaw gateway health --port <n>` from a background subshell — and both log under the command
name `gateway`. Written a line at a time the two records interleave, and a reader then attributes
the registrar's arguments to the exec. That is not a theory: one run in twenty reported the
gateway's `--bind` as `3000`, because the exec wrote `ARG [--bind]` and the registrar's
`ARG [3000]` landed between it and `ARG [lan]`. `argv_flag_value` reads one invocation at a time
for the same reason, and takes the last matching one by default because the invocation a case
cares about is the one the entrypoint ends on.

**`config validate` has no schema opinion, but it can still fail.** 004's stub carries a
transcription and 006's `config-schema-check` runs the real validator against the real schema; a
third opinion here would only be a third thing to keep in step with upstream. It does honour
`OPENCLAW_STUB_VALIDATE_ERROR`, because what the phase 3 gate *does* with a failure — pass the
validator's message to `docker logs` through a redaction filter — became 007's problem the moment
007 put a fifth credential into the file being validated.

## What 006 cannot see, and why this suite has to

`config-schema-check` runs the real entrypoint and diffs the configuration it produces against
the seed onboarding handed it. It is structurally blind to `gateway.bind`: the seed mirrors
whatever flag the entrypoint passed, so the key is identical on both sides whatever the
entrypoint does with it. An entrypoint that stopped writing `gateway.bind`, or wrote the wrong
value, would not move that diff by a byte. `bind-test` is where that assertion lives.

The corollary is the good news: because the two sides move together, and because auth is only
written for a non-loopback bind, this change adds no key to 006's coverage diff and needs no
edit to its expected table. That was checked, not assumed — `bin/test` is green before and
after.

## The digests

`provisioning-test` asserts the shape of the pinned digests, that every architecture the role
can resolve has one, and that no download in either role is unverified. What it does not do by
default is ask upstream whether the digests are *right*, because that means fetching the release
manifest on every run:

```bash
HERMES_CHECK_UPSTREAM=1 .specs/007-gateway-supply-chain-hardening/tests/provisioning-test
```

That compares `openclaw_gog_checksums` against the digests published in the release's own
`checksums.txt`. The digests committed here were produced the stronger way — by downloading both
Linux tarballs and hashing them, then confirming the result against `checksums.txt` — and the
whole pipeline was run once against a scratch directory to confirm that `get_url` + `unarchive`
installs a working `gog v0.39.1` and that a wrong digest fails the build and leaves nothing
behind.

The apt signing keys fetched by `roles/node` and `roles/claude-code` carry no checksum. That is
deliberate scope, not an oversight: they are verified by apt against the repository signature,
and SPEC § Structural Impact names only gog and fastText. Worth a follow-up spec, not a silent
widening of this one.

## What still needs a container

- **The probes `PLAN.md` task 1 asks for.** `openclaw config get gateway.bind`,
  `gateway.auth.mode` and `gateway.auth.token` against a real, already-onboarded container. The
  upstream documentation answers the question they were asked — onboarding uses token auth by
  default and generates a token — which makes A3 an *unmanaged credential* rather than an
  unauthenticated bind. That is doc-verified, not execution-verified, and the probes are still
  owed.
- **A real gateway refusing a real unauthenticated non-loopback bind.** The entrypoint now makes
  that combination unreachable, so the upstream behaviour it defers to is never exercised here.
- **`openclaw --version` and `gog --version` inside two builds of the same commit**, which is the
  reproducibility criterion. `gog --version` was confirmed against a real install of the pinned
  artefact; `openclaw --version` inside the image was not.
- **The published port.** That a `loopback` bind is unreachable through `-p 127.0.0.1:3000:3000`
  under bridge networking, and that `lan` plus a token restores it, is upstream-documented and
  standard Docker behaviour — but no case here can bind a socket.
