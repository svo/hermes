# Plan: Lint and test gate

> Adapted from the `plan` skill — see [`.specs/README.md`](../README.md) § Template adaptation.
> Spec: [`SPEC.md`](SPEC.md)

## Preconditions

`bin/test` fails on the current `main`: five shellcheck findings in `hermes-check`
(`:38`, `:112`, `:123`, `:150`, `:151`) and the `risky-shell-pipe` in
`roles/openclaw/tasks/main.yml:15-19`.

Two ways to land it:

- **After 001 and 005** (default). The tree is already clean; the gate passes on its first
  run and stays meaningful from day one.
- **Pulled forward to position one.** Start with `shellcheck --severity=warning` and
  `ansible-lint` warnings non-fatal, so the gate is live but the known baseline does not
  block. Tighten to `--severity=info` and fatal ansible-lint as the final task of 005. If
  you take this path, **write the tightening into 005's task list**, or the loosened
  thresholds become permanent — which is the same "gate exists but does nothing" failure this
  spec is fixing, one level up.

Do not suppress findings inline with `# shellcheck disable=`. The two SC2086 warnings in
particular are real design smells (C10), not noise.

## Implementation Strategy

Write the file the image already claims to run. `builder.pkr.hcl:6` declares
`ENTRYPOINT ["./bin/test"]` with `WORKDIR /working-dir`, and `build.sh` mounts the repo
there — so the contract already exists and only the file is missing. Honour that contract
exactly, so `docker run svanosselaer/hermes-builder` runs the checks with no override.

`bin/test` runs every check and **accumulates** failures rather than exiting on the first.
One CI run should reveal every problem; a fail-fast gate turns a three-problem branch into
three round trips.

CI gets a `lint` job that `matrix` depends on, so a lint failure prevents the build and push
entirely. Per SPEC Open Question 4, factor it into a reusable workflow rather than copying
the job into all three files — three copies would drift, which is the same class of problem
as the duplicated briefing prompt in 003.

## Layer Changes

### Provisioning
None. `playbook-builder.yml` already installs `shellcheck` and `ansible-lint`.

### Image & CI

**`bin/test`** — new, executable, `set -euo pipefail`, accumulating:
1. `bash -n` over every shell script.
2. `shellcheck -s bash` over `infrastructure/ansible/roles/*/files/*` and `bin/*`,
   `build.sh`, `push.sh`, `create-latest.sh`. Discover by content, not by extension —
   `hermes-check`, `bin/test`, and `bin/create-image` have no `.sh` suffix and would be
   missed by a glob.
3. `ansible-lint infrastructure/ansible`.
4. `bin/hermes-check-test` (from 005), skipped with a notice if absent.
5. `openclaw config validate` against the generated fixture (Open Question 3 → stub).
6. Summary listing every failing check; exit non-zero if any failed.

**`.github/workflows/lint.yml`** — new reusable workflow (`workflow_call`) that checks out,
builds or pulls the builder image, and runs `./bin/test`.

**`builder.yml` / `development.yml` / `service.yml`** — add a `lint` job calling the
reusable workflow; add `needs: [lint]` to `matrix`. Also add `pull_request` triggers so the
gate runs before merge, not only after.

### Runtime configuration / agent pipeline / instructions
No change. This spec verifies behaviour; it does not alter it.

### Documentation
- `README.md` — a Contributing section: `./bin/test` before pushing, and `SKIP_SLOW=1` for
  fast local iteration.

## Configuration Contract

| In | Out |
|---|---|
| repository at `/working-dir` | exit 0, or non-zero naming each failing check |
| `SKIP_SLOW=1` | container smoke tests skipped |
| absent `bin/hermes-check-test` | that check skipped with a visible notice, not silently |

## Task List

1. [ ] ci: add `bin/test` with `bash -n` and `shellcheck` only; confirm it fails on current
       `main` for the five known findings. **The gate must be seen to fail before it is
       trusted.**
2. [ ] ci: add `ansible-lint`; confirm it flags `risky-shell-pipe` at
       `roles/openclaw/tasks/main.yml:15-19`.
3. [ ] provisioning: fix `risky-shell-pipe` — add `executable: /bin/bash` and
       `set -o pipefail` to the gog install task. Smallest fix that clears the check.
4. [ ] ci: add failure accumulation and the summary.
5. [ ] ci: wire in `bin/hermes-check-test` with a skip-if-absent notice.
6. [ ] ci: add the `openclaw config validate` fixture check.
7. [ ] ci: add `.github/workflows/lint.yml` as a reusable workflow.
8. [ ] ci: add `needs: [lint]` and `pull_request` triggers to all three workflows.
9. [ ] ci: verify the builder image runs `bin/test` with no entrypoint override (E1).
10. [ ] docs: README Contributing section.
11. [ ] ci: tighten thresholds — only if this spec was pulled forward. Otherwise omit.

## Testing Strategy

The gate tests the repository; these test the gate.

- **Red-then-green on the gate itself** — tasks 1 and 2 require `bin/test` to fail on known
  findings before anything is fixed. A gate that has only ever passed is indistinguishable
  from one that checks nothing, which is exactly how `bin/test` came to be missing.
- **Injected-violation check** — add a deliberate shellcheck violation on a scratch branch,
  confirm CI fails and no image is pushed. This verifies the `needs:` wiring, not just the
  script.
- **Discovery check** — assert `bin/test` finds `hermes-check` and `bin/create-image`
  (extensionless). A glob-based discovery would silently skip the file with all five
  findings.
- **Parity check** — same exit code locally and in CI for the same commit.
- **Skip-path check** — with `bin/hermes-check-test` absent, the notice appears and the
  overall result is still meaningful.
- Naming: `should_<behaviour>_when_<condition>`.

## Operability Plan

- One line per check: `PASS shellcheck`, `FAIL ansible-lint`.
- Full tool output for failures only.
- Final summary lists every failing check.
- The CI job name states what it gates, so a red build is self-explanatory in the PR list.

## Risks and Mitigations

- **Risk:** the gate lands loosened "temporarily" and stays that way. → **Mitigation:** the
  tightening is task 11 here *and* a task in 005; if pulled forward it must exist in both.
- **Risk:** a lint job on every push slows the pipeline. → **Mitigation:** lint runs on one
  runner and gates a two-platform matrix build — it saves time on failures.
- **Risk:** contributors bypass it locally and discover failures in CI. → **Mitigation:**
  `./bin/test` runs through the same builder image CI uses; document it in the README.
- **Risk:** `ansible-lint` version drift changes the rule set and breaks unrelated builds.
  → **Mitigation:** 007 pins the toolchain; until then, expect occasional churn and note it.
- **Risk:** the config-validate fixture drifts from the real entrypoint logic.
  → **Mitigation:** generate it by running the actual mutation code against a stub rather
  than checking in a static file (Open Question 3).
- **Risk:** `pull_request` triggers expose `secrets.DOCKER_*` to fork PRs.
  → **Mitigation:** the `lint` job needs no secrets — do not grant it any, and keep the
  push steps on `push`-triggered jobs only. Verify before merging task 8.
