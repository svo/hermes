# 007 checks

Verification for [SPEC.md](../SPEC.md). No image, no credentials, no Anthropic key: the roles are
read as YAML, and the stubs and harness that the entrypoint cases will use land here with them.

```bash
.specs/007-gateway-supply-chain-hardening/tests/run
```

| File | What it is |
|---|---|
| `run` | Entry point. Runs every check, accumulating failures rather than stopping at the first. |
| `harness.sh` | Shared assertions and the hermetic runner. Sourced, not run. |
| `provisioning-test` | Track 2 — the pins, the digests, and the build-time lookup that is gone. |
| `stub-openclaw` | Fake `openclaw`: `onboard`, `gateway`, `gateway health`, `config get`, `config validate`, `automations list`. |
| `stub-gog` | Fake `gog`. Records and succeeds. |

Fifteen cases, all in `provisioning-test`; one skips unless `HERMES_CHECK_UPSTREAM=1`.

The harness and both stubs arrive with this commit rather than with the entrypoint tracks that
use them, because `provisioning-test` sources the harness for its assertions and the harness
stands its sandbox up as a side effect of being loaded. Tracks 1 and 3 add `bind-test`,
`permissions-test` and `mutation-check` on top.

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
than by extension, so `run`, `harness.sh`, both stubs and every suite go through `bash -n` and
`shellcheck -x -P SCRIPTDIR -s bash` on every CI run.

**If you would rather have it in CI**, the change is one `check` call in `bin/test` next to the
`config-schema` one, plus a re-run of 006's suite to confirm the sandbox timings and the
red-baseline count still hold.

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

- **`openclaw --version` and `gog --version` inside two builds of the same commit**, which is the
  reproducibility criterion. `gog --version` was confirmed against a real install of the pinned
  artefact; `openclaw --version` inside the image was not.
