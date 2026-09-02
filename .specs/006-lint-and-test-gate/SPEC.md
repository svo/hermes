# Feature: Lint and test gate

> Adapted from the `specify` skill — see [`.specs/README.md`](../README.md) § Template adaptation.

## Overview

The quality gate for this repository was designed, provisioned, and never connected.

The builder image installs `shellcheck` and `ansible-lint` — dedicated Ansible roles for
each, with `ansible-lint` even carrying retry logic. `builder.pkr.hcl` declares
`ENTRYPOINT ["./bin/test"]`. **`bin/test` does not exist**, and none of the three workflows
runs a lint or test step; they build and push only.

That single gap explains most of the review's findings: five live shellcheck warnings, an
ansible-lint `risky-shell-pipe` violation, and every unvalidated OpenClaw config key. The
tooling was ready the whole time.

This spec writes `bin/test` and makes CI run it.

## Source Findings

| ID | Claim | Anchor | Confidence |
|---|---|---|---|
| E1 | `bin/test` is the declared builder entrypoint and does not exist | `builder.pkr.hcl:6`; `ls bin/` | execution-verified |
| E2 | shellcheck and ansible-lint are installed but never invoked | `roles/shellcheck/`, `roles/ansible-lint/`, `playbook-builder.yml` | internal-contradiction |
| E3 | No workflow runs lint or tests | `.github/workflows/*.yml` | internal-contradiction |
| E4 | Five live shellcheck findings | `hermes-check:38,112,123,150,151` | execution-verified |
| E5 | `curl \| tar` without `pipefail` — ansible-lint `risky-shell-pipe` | `roles/openclaw/tasks/main.yml:15-19` | doc-verified |
| D2 | Config keys hand-written into strict schemas with no validation | `entrypoint.sh:30-75` | doc-verified |

## User Stories

- As the maintainer, I want lint failures to break the build, so that the next SC2106 is
  caught in CI instead of in production monitoring.
- As the maintainer, I want the declared builder entrypoint to exist, so that the image does
  what its own definition says.
- As the maintainer, I want config schema violations caught at build time, so that an
  upstream rename fails a pipeline instead of every running container.
- As a contributor, I want to run the same checks locally that CI runs, with one command.
- As the maintainer, I want the gate to run before push, so a broken image is never
  published.

## Acceptance Criteria

- [ ] Given the repository, when `./bin/test` is run, then it executes shellcheck over every
      shell script, ansible-lint over the Ansible tree, `bash -n` over every script, and the
      `hermes-check` harness.
- [ ] Given any check fails, when `./bin/test` runs, then it exits non-zero and names the
      failing check.
- [ ] Given all checks pass, when `./bin/test` runs, then it exits zero.
- [ ] Given `docker run svanosselaer/hermes-builder`, when no entrypoint override is given,
      then `bin/test` runs — matching `builder.pkr.hcl:6`.
- [ ] Given a pull request or push to `main`, when CI runs, then `./bin/test` runs **before**
      the build step and a failure prevents build and push.
- [ ] Given a script with a shellcheck violation is committed, when CI runs, then it fails.
- [ ] Given an OpenClaw config fixture with an invalid key, when `./bin/test` runs, then it
      fails with the validator's message.
- [ ] Given a contributor runs `./bin/test` locally, then it produces the same result as CI.
- [ ] Given the current `main`, when `./bin/test` is first run, then it passes — requiring
      001 and 005 to have landed, or a documented baseline.

## Structural Impact

### Provisioning
- No role changes. `shellcheck` and `ansible-lint` are already installed by the builder
  playbook; this spec finally uses them.

### Runtime configuration / agent pipeline
No change. This spec adds no behaviour to the running container — it verifies it.

### Image & CI
- `bin/test` — new. The missing entrypoint.
- `.github/workflows/{builder,development,service}.yml` — a `lint` job gating `matrix`.
- `bin/hermes-check-test` — created by 005; invoked here.
- A config fixture for `openclaw config validate` at build time.

### Documentation
- `README.md` — a contributing note: run `./bin/test` before pushing.

## Configuration Contract

| In | Out |
|---|---|
| repository checkout | exit 0 (all checks pass) or non-zero (named failing check) |
| `SKIP_SLOW=1` (optional) | skips the container smoke tests for fast local iteration |

`bin/test` takes no required arguments and needs no credentials or network beyond the
builder image's own tooling.

## Operability

- Each check prints a single pass/fail line; failures print full tool output.
- The summary names every failing check, not just the first — one CI run should reveal all
  problems.
- Runs identically locally and in CI, via the builder image, so "works on my machine" is not
  reachable.

## Dependencies

- **Depends on 001 and 005.** `bin/test` fails shellcheck until E4's five findings are
  resolved. See `PLAN.md` § Preconditions for the alternative if this spec is pulled forward.
- **Consumes 005's harness** (`bin/hermes-check-test`).

## Open Questions

1. **Pull forward to position one?** A gate written first would catch 005's bugs on the way
   in. It sits at six because it closes no live security exposure. If pulled forward, adopt
   the staged-severity approach in `PLAN.md` § Preconditions.
2. **Fail on shellcheck `info` or only `warning` and above?** The five current findings are
   two `info` (SC2086) and three `warning` (SC2106). Recommendation: fail on `warning` and
   above initially, tighten to `info` once 005 lands. Confirm.
3. **Config validation fixture.** `openclaw config validate` needs a config to validate.
   Generate one by running the entrypoint's mutation logic against a stub, or check in a
   representative fixture that must be updated with the entrypoint? The stub approach tests
   the real code path; the fixture is simpler but can drift. Recommendation: stub.
4. **Should `bin/test` run in the `service` workflow too?** It duplicates work across three
   workflows. A single reusable workflow called by all three avoids drift.
