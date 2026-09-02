# Specs

Seven specifications derived from the adversarial review of the OpenClaw configuration.
Each directory holds a `SPEC.md` (what and why) and a `PLAN.md` (how), following the
`/specify` → `/plan` workflow.

## Template adaptation

The `specify` and `plan` skills are written for **Colors of Meaning** — a Python
hexagonal-architecture service (`src/colors_of_meaning/{domain,application,infrastructure,interface,shared}`,
FastAPI, Pydantic, Lagom DI, pytest-archon, assertpy, tox). Hermes is an
Ansible + Packer + bash + Docker repository with no Python source, no `CLAUDE.md`,
and no test framework.

The skills' **process** is followed verbatim: spec before code, user stories,
Given/When/Then acceptance criteria, structural impact, open questions; then strategy,
ordered independently-committable tasks, testing strategy, risks and mitigations.

The skills' **hexagonal layer sections** have no analogue here and are replaced with this
repository's actual structural layers:

| Skill section | Hermes equivalent |
|---|---|
| Domain layer | **Provisioning** — `infrastructure/ansible/roles/*/tasks/main.yml` |
| Application layer | **Runtime configuration** — `roles/openclaw/files/entrypoint.sh` |
| Infrastructure layer | **Agent pipeline** — `roles/openclaw/files/hermes-check` |
| Interface layer | **Agent instructions** — `AGENTS.md` / `SOUL.md` / `IDENTITY.md` / `USER.md` heredocs, heartbeat and cron prompts |
| Shared layer | **Image & CI** — `infrastructure/packer/*.pkr.hcl`, `.github/workflows/*`, `bin/*` |
| Dependency Injection | **Configuration contract** — env vars in, `openclaw.json` keys out |
| Observability | **Operability** — what the operator can see and verify |

## Order

Numbering follows the review's recommended sequence. Live security exposure and silent
failures come before the systemic fix.

| # | Spec | Review findings | Why here |
|---|---|---|---|
| 001 | [sanitize-untrusted-content](001-sanitize-untrusted-content/SPEC.md) | A1 | Smallest diff, largest risk reduction |
| 002 | [slack-access-control](002-slack-access-control/SPEC.md) | A2 | One key closes an open door |
| 003 | [cron-registration-via-cli](003-cron-registration-via-cli/SPEC.md) | B1 | A headline feature that probably never runs |
| 004 | [entrypoint-startup-correctness](004-entrypoint-startup-correctness/SPEC.md) | B2, B3, B4, B5, B6 | Small edits, removes crash and silent-wipe paths |
| 005 | [hermes-check-correctness](005-hermes-check-correctness/SPEC.md) | C1–C5, C10, C11 | The monitoring is the product |
| 006 | [lint-and-test-gate](006-lint-and-test-gate/SPEC.md) | E | Systemic fix; stops 005 recurring |
| 007 | [gateway-supply-chain-hardening](007-gateway-supply-chain-hardening/SPEC.md) | A3, D1, D2, D5 | Posture and stability |

**006 may be pulled forward.** In a green-field ordering the lint gate would come first,
because it would catch 005's bugs automatically on the way in. It sits at position six
because a lint gate does not close an open Slack door. If you would rather have the gate
catch regressions during 001–005, swap 006 to position one and accept that its first CI run
fails until 001 and 005 land — see `006/PLAN.md` § Preconditions.

## Dependency graph

```
001 ──┐
      ├──> 005 ──> 006
002 ──┤              ^
003 ──┤              |
004 ──┴──────────────┘
007 (independent, but 007's pinning makes 006's CI deterministic)
```

- **005 depends on 001** — 001 introduces `sanitize_field()`; 005 consumes it.
- **006 depends on 001 + 005** — `bin/test` runs `shellcheck` with a failing exit code;
  the five SC2086/SC2106 findings must be resolved first or the first CI run breaks.
- **003 depends on 004** — 004 establishes the early-validation block that 003's registrar
  relies on for a guaranteed-present `HERMES_CRON_SCHEDULE` and `HERMES_TIMEZONE`.

## Shared-file ownership

Four specs edit `entrypoint.sh` and two edit `hermes-check`. To keep the changes
non-colliding, each plan declares an owned region. No two specs modify the same lines.

| File | Region | Owner |
|---|---|---|
| `entrypoint.sh` | 1–99 (shebang, `TZ` export, required-vars block) and ordering within the first `node -e` block | **004** |
| `entrypoint.sh` | 248–262 (Slack block) | **002** |
| `entrypoint.sh` | 264–285 (cron block — deleted) and the registrar inserted before `exec` | **003** |
| `entrypoint.sh` | 12 and 287 (bind flags), plus an appended permissions step | **007** |
| `hermes-check` | `sanitize_field()` helper and the emit sites | **001** |
| `hermes-check` | VIP matching, counters, jq guards, date parsing | **005** |

## Evidence and confidence

Every requirement traces to a review finding with a `file:line` anchor and one of four
confidence labels:

- **doc-verified** — confirmed against upstream OpenClaw docs via context7
- **execution-verified** — reproduced by running the code
- **internal-contradiction** — the repository contradicts itself; true regardless of upstream
- **verify-locally** — plausible, with a stated one-command check

Requirements marked *verify-locally* carry the check that would falsify them. Run it before
implementing that requirement.
