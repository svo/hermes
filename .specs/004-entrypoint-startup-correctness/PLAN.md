# Plan: Entrypoint startup correctness

> Adapted from the `plan` skill — see [`.specs/README.md`](../README.md) § Template adaptation.
> Spec: [`SPEC.md`](SPEC.md)

## Implementation Strategy

One organising principle: **validate everything before writing anything.**

The current script interleaves validation with side effects, which is why a missing variable
can leave onboarding done, credentials written, and the config half-mutated. Restructure the
top of the file into three ordered phases with no overlap:

```
Phase 1  validate    — no writes, no network, no side effects
Phase 2  configure   — onboarding, credentials, config mutation
Phase 3  verify      — openclaw config validate, then exec
```

Phase 1 must run before `export TZ`, because `set -u` turns that line into an abort that
pre-empts the friendly error (B4b). This is the smallest change with the largest effect and
should be the first commit.

Phase 3 is the new gate. `openclaw config validate` checks against the active JSON schema
without starting the gateway, which is exactly the guard missing from D2 — an upstream key
rename becomes a diagnosable startup error instead of a container that bricks on restart.

Two safety changes are about **not destroying state**:

- `exec-approvals.json` becomes write-if-absent, so operator edits survive (B6).
- `ANTHROPIC_API_KEY` joins `required_vars`, so an undefined value can never reach
  `JSON.stringify` and silently delete the persisted key (B4c). Phase 1 ordering means the
  config file is never opened when the variable is missing.

## Layer Changes

### Provisioning
None.

### Runtime configuration (`roles/openclaw/files/entrypoint.sh`)
Owned regions: `:1-99` and the internal ordering of `:30-75`.

**Phase 1 — relocate to immediately after the shebang and `set -euo pipefail`:**
- Move the `required_vars` array and the `missing` loop from `:77-99` to the top.
- Add `ANTHROPIC_API_KEY` to the array.
- Add conditional rules: `TELEGRAM_ALLOW_FROM` required when `TELEGRAM_BOT_TOKEN` is set;
  `SLACK_APP_TOKEN` and `SLACK_ALLOW_FROM` required when `SLACK_BOT_TOKEN` is set. Rule
  origin: 002. Collect all violations, report once.
- Only then `export TZ="${HERMES_TIMEZONE}"`.

**Phase 2 — minimal edits, ordering only:**
- Move `config.tools = config.tools || {}` (`:64`) above `config.tools.loopDetection`
  (`:51`). Audit the block for any other guard-after-use of the same shape.
- Guard the `exec-approvals.json` heredoc (`:21-28`) with `[ ! -f ... ]`.
- Add `config.commands = config.commands || {}` and set `ownerAllowFrom` — see Open
  Question 2 for the derivation.
- Leave `:241`'s Telegram `.split` as is at this layer; Phase 1 now guarantees the variable
  exists, which is the real fix for B3a. Add a defensive `|| ''` only if task 6's test shows
  a residual path.

**Phase 3 — new, immediately before `exec`:**
- `openclaw config validate` — on non-zero, print the validator's output and exit non-zero.
- Sequence before 003's background registrar so an invalid config never reaches it.

**Do not** touch `:248-262` (002), `:264-285` (003), or `:12`/`:287` flags (007).

### Documentation
- `README.md:105-107` — delete the `pairing` fallback claim and the "message the bot without
  `TELEGRAM_ALLOW_FROM`" instruction; state that the variable is required with the token and
  document how to obtain a Telegram user ID by another route.
- Environment table — `ANTHROPIC_API_KEY` required; note up-front validation.

## Configuration Contract

| In | Out |
|---|---|
| All required vars present | proceed to Phase 2 |
| Any missing | single error listing all, exit non-zero, **zero writes** |
| Config written | `openclaw config validate` must exit zero before `exec` |
| `exec-approvals.json` exists | left untouched |

## Task List

1. [ ] runtime-config: move the `required_vars` block above `export TZ`. Smallest diff,
       fixes B4b outright.
2. [ ] runtime-config: add `ANTHROPIC_API_KEY` to `required_vars` (B4c).
3. [ ] runtime-config: add the conditional Telegram and Slack rules (B3a).
4. [ ] runtime-config: move the `config.tools` guard above its first use; audit for siblings
       (B2).
5. [ ] runtime-config: make `exec-approvals.json` write-if-absent (B6).
6. [ ] runtime-config: set `commands.ownerAllowFrom` (B5).
7. [ ] runtime-config: add the `openclaw config validate` gate before `exec` (D2).
8. [ ] tests: env-permutation matrix — each required variable omitted in turn; assert the
       named error, exit code, and that no file was written.
9. [ ] tests: state-preservation — configure fully, restart without `ANTHROPIC_API_KEY`,
       assert the persisted key is intact.
10. [ ] tests: approvals-preservation — edit `exec-approvals.json`, restart, assert the edit
        survives.
11. [ ] docs: correct the README's Telegram section and environment table.

Tasks 1–3 are worth landing as one commit; they are the fail-fast behaviour and are hard to
test in isolation.

## Testing Strategy

No test framework exists. Verification is container-level:

- `bash -n` and `shellcheck` after every task.
- **Permutation matrix** — for each required variable, run the container with it omitted and
  assert: non-zero exit, the variable named in stderr, and — critically — that
  `/opt/hermes/data/openclaw.json` is unchanged. That last assertion is what proves Phase 1
  actually precedes the writes rather than merely appearing earlier in the file.
- **Golden-file check** — capture `sha256sum openclaw.json` before a failing start and after;
  they must match.
- **Schema gate** — deliberately inject a bogus key, assert startup fails with the validator's
  message and the gateway does not start.
- **Negative-path clarity** — assert stderr contains no `TypeError` and no `unbound variable`
  in any permutation. Those two strings are the regression markers for B3a and B4b.
- Naming: `should_<behaviour>_when_<condition>`.

## Operability Plan

- Exactly one error block on a failed start, listing every missing variable — not one per
  run, which would make a three-variable misconfiguration a three-restart discovery.
- Schema failures print the validator's own key path.
- Verification: `openclaw config validate --json`,
  `openclaw config get commands.ownerAllowFrom`.

## Risks and Mitigations

- **Risk:** reordering the script breaks a dependency that is not obvious from reading it
  (something in the config block relying on `TZ`). → **Mitigation:** `TZ` is exported in
  Phase 1 immediately after validation, so it is set earlier than before, never later.
- **Risk:** adding `ANTHROPIC_API_KEY` to `required_vars` breaks a deployment that relies on
  the key already being persisted. → **Mitigation:** real behaviour change; today that path
  silently wipes the key, so failing loudly is strictly better. Call it out in the release
  note.
- **Risk:** `openclaw config validate` rejects a config that previously worked, blocking
  startup. → **Mitigation:** this is the point — it fails at deploy time with a message
  rather than at restart time without one. Run it against the current config **before**
  wiring the gate, so any existing violations are known up front. Do this in task 7.
- **Risk:** write-if-absent for `exec-approvals.json` means an intentional default change
  never reaches existing containers. → **Mitigation:** document that the file is
  operator-owned after first creation; changing the shipped default requires deleting it.
- **Risk:** `ownerAllowFrom` derived from Telegram IDs misroutes when only Slack is
  configured. → **Mitigation:** Open Question 2; prefer an explicit `HERMES_OWNER`.
- **Risk:** touching `:241` collides with 002's Slack work. → **Mitigation:** region
  ownership; Phase 1 fixes B3a without editing the Telegram block at all.
