# Specs

Nine specifications. Seven derive from the adversarial review of the OpenClaw configuration;
008 and 009 were deferred out of 004 as its open questions were answered, and carry their
findings with them. Each directory holds a `SPEC.md` (what and why) and a `PLAN.md` (how),
following the `/specify` → `/plan` workflow. All nine are planned and landed.

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
| 008 | [config-via-cli](008-config-via-cli/SPEC.md) | D2, D3–D6 | Dissolves the hand-written-key class 004 could only gate |
| 009 | [channel-teardown](009-channel-teardown/SPEC.md) | A2g, B3d | Removing a token should remove the channel |

**008's `verify-locally` check has been run**, and it decided the shape of the plan. Two of its
five findings changed verdict: D4 is falsified (`tools.exec.security` *is* in the schema, enum
`deny|allowlist|full`), and D3 is worse than stated — the `exec-approvals.json` the container
wrote does not merely do nothing, it puts exec approvals into a blocked legacy state. See
[`008/PLAN.md`](008-config-via-cli/PLAN.md) § The probe, first.

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
 │
 ├──> 008   (needs 004's validate gate and phase ordering)
 └──> 009   (needs 004's phase 3 to leave a valid config for)
007 (independent, but 007's pinning makes 006's CI deterministic)
```

- **005 depends on 001** — 001 introduces `sanitize_field()`; 005 consumes it.
- **006 depends on 001 + 005** — `bin/test` runs `shellcheck` with a failing exit code;
  the five SC2086/SC2106 findings must be resolved first or the first CI run breaks.
- **003 depends on 004** — 004 establishes the early-validation block that 003's registrar
  relies on for a guaranteed-present `HERMES_CRON_SCHEDULE` and `HERMES_TIMEZONE`.
- **008 and 009 depend on 004** — both sit inside the three-phase ordering it established, and
  both have to leave a config its phase 3 gate will accept.

## Shared-file ownership

Six specs edit `entrypoint.sh` and two edit `hermes-check`. To keep the changes
non-colliding, each plan declares an owned region. No two specs modify the same lines.

Regions are named by content, not by line number. Each spec that lands moves every line below
it, so the numbers written into `SPEC.md` and `PLAN.md` are the ones that were true when they
were written — anchor on the content instead. 001 through 008 have landed; 003 replaced a
22-line block with a 230-line one, 005 rewrote the calendar loops around a single parse, 007
added roughly 180 lines between the channel blocks and the phase 3 gate, and 008 replaced the
first `node -e` block with a payload builder and a piped setter.

007 and 008 are the deliberate exceptions to "no two specs modify the same lines". Each crosses
into 004 twice.

**009 crosses into nothing.** It is one new block between two existing ones, and neither 002's
Slack region nor the Telegram block nor any of 004's phases changed a line — which is what the
spec meant by "one mechanism should cover both". Its suite is 008's harness and stub with two
changes, both forced by the same fact: the entrypoint now issues a *second* `config patch`, so
the stub records patch documents one per line instead of overwriting, and its rejection can be
aimed at one of them. 008's own suite is unaffected and was run either side.

The first is sanctioned by its own plan: the bind/token rule lives inside 004's phase 1
validation block, because `007/PLAN.md` task 3 says to register it there rather than add a second
validation site — one error block should still list every violation. It is an added `case` in
`explain_variable` and an added conditional; it alters no existing line. The conditional is
placed *below* the owner derivation on purpose, because 004's owner check only demands
HERMES_OWNER while `missing` is still empty, and a gateway token counted above it would silence a
real owner problem and cost a second restart.

The second was not planned and is not optional. 007 writes a fifth credential into
`openclaw.json`; 004's phase 3 gate passes `openclaw config validate`'s output to `docker logs`
through `redact_secrets`, which listed four. One entry was added to that list. A spec that adds a
secret to a file owns the redaction of that secret wherever the file is read aloud — leaving it
to 004 would have meant shipping the leak and filing it.

004's mutation anchors are unaffected by either of 007's crossings, and 004's suite was unchanged
either side of it.

**008 crosses into 004 twice as well**, and both are declared in its plan rather than discovered
afterwards.

The first is the `exec-approvals.json` guard. The table gives it to 004, which wrote `[ ! -f ]`
to stop a restart reverting an operator's tightened `defaults.security`. 008 removes the write
entirely — its acceptance criterion 4 names that file — having found the format retired and a
leftover one actively blocking exec approvals. 004's reason for the guard is honoured rather than
discarded: `openclaw doctor --fix` *imports* the operator's policy into SQLite instead of
deleting it, so a tightened setting survives.

The second is hoisting `redact_secrets` above phase 2. 004 defined it immediately above its phase
3 gate, the only place that read the config aloud; 008 gives phase 2 a second one, because
`openclaw config patch` quotes the payload back when it rejects it and that payload carries the
Anthropic key. The definition moves, its body does not change, and bash resolves function names
at call time, so the phase 3 gate calls exactly what it always did. Same rule as 007's second
crossing: a spec that puts a credential where something reads it aloud owns the redaction of it.

008 also changed five of 004's own cases and two of its stub's tables, because it inverted the
behaviour they pinned: `state-test`'s three approvals cases, `config-test`'s `loopDetection`
assertions, `gate-test`'s unverified-key list, the stub's `UNVERIFIED` list — which named
`tools.exec.security` as a key nobody had checked, so 008 checked it and emptied the list, the
outcome 004 was pinning the way to — and its `TOOLS_EXEC_KEYS`, which had to learn the key that
list stopped excusing. `harness.sh` gained a `doctor_ran` helper.

Two of those 004 assertions were already red on `main` before 008 began: `config-test` and
`gate-test` still named the three `loopDetection` thresholds that `78ba48e` removed from the
entrypoint. They are fixed here, and 004's suite is green again.

007's `permissions-test` changes too, for the same reason rather than as a crossing: the file
whose mode it asserted is no longer written, so the case became "no file is written", and a new
one covers the mode of a legacy file a failed migration leaves behind. 007's stub learned
`doctor` because the entrypoint can now call it.

| File | Region | Owner |
|---|---|---|
| `entrypoint.sh` | The shebang, the `TZ` export, the phase 1 validation block, ordering within the first `node -e` block, the `exec-approvals.json` guard, and the phase 3 `config validate` gate | **004** |
| `entrypoint.sh` | The `SLACK_BOT_TOKEN` block | **002** |
| `entrypoint.sh` | ~~The `jobs.json` `node -e` block~~ (deleted) and the briefing registrar between the Slack block and `exec` | **003** |
| `entrypoint.sh` | The bind flags on `openclaw onboard` and on the final `exec openclaw gateway`; the gateway bind/auth block and the permissions step between the channel blocks and the phase 3 gate; the `0600` chmod after onboarding; and, inside 004's regions, the `HERMES_GATEWAY_BIND`/`HERMES_GATEWAY_TOKEN` rule in phase 1 and the `HERMES_GATEWAY_TOKEN` entry in `redact_secrets` | **007** |
| `hermes-check` | `sanitize_field()` helper and the emit sites | **001** |
| `hermes-check` | VIP matching, counters, jq guards, date parsing | **005** |
| `entrypoint.sh` | The first `node -e` block, now a payload builder piped into `openclaw config patch`, and the `tools.exec.security` write-if-absent immediately below it; and, inside 004's regions, the `exec-approvals.json` guard and the position of `redact_secrets` | **008** |
| `entrypoint.sh` | The channel-teardown block between the Slack block and 007's gateway bind/auth block — after both channel blocks, because they write the file this one reads, and above 007's, because the permissions sweep has to stay downstream of every write | **009** |

## Evidence and confidence

Every requirement traces to a review finding with a `file:line` anchor and one of four
confidence labels:

- **doc-verified** — confirmed against upstream OpenClaw docs via context7
- **execution-verified** — reproduced by running the code
- **internal-contradiction** — the repository contradicts itself; true regardless of upstream
- **verify-locally** — plausible, with a stated one-command check

Requirements marked *verify-locally* carry the check that would falsify them. Run it before
implementing that requirement.
