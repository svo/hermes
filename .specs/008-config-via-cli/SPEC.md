# Feature: Configuration through the CLI rather than by hand

> Adapted from the `specify` skill — see [`.specs/README.md`](../README.md) § Template adaptation.
> Deferred from [`004`](../004-entrypoint-startup-correctness/SPEC.md) § Open Questions 1.

## Overview

`entrypoint.sh` builds `openclaw.json` by reading the file into `node -e`, mutating an object,
and writing it back. Roughly fifteen keys are spelled out by hand, in a file whose schemas are
strict — so a key that is renamed, moved or retired upstream becomes a container that either
refuses to start or, worse, starts with the setting silently doing nothing.

004 added `openclaw config validate` before the gateway starts, which turns the first outcome
into a named error. It does not address the second, and it does not stop the next wrong key
being written. Upstream publishes non-interactive, path-based setters that validate as they
write; using them dissolves the class rather than reporting it.

Three keys are already known to be affected, and 004 found all three on paper because there was
no image to check against.

## Source Findings

| ID | Claim | Anchor | Confidence |
|---|---|---|---|
| D2 | ~15 keys hand-written into strict schemas with no validation step | `entrypoint.sh` first `node -e` block | doc-verified |
| D3 | `~/.openclaw/exec-approvals.json` is retired; approvals live in SQLite at `~/.openclaw/state/openclaw.sqlite#exec_approvals_config`, and upgrading is a one-off `openclaw doctor --fix` that imports the file. The container still writes the file, so its `security: full` default may be doing nothing | `entrypoint.sh` approvals heredoc | doc-verified |
| D4 | `tools.exec.security` is absent from the documented `tools.exec` key list | `entrypoint.sh` first `node -e` block | verify-locally |
| D5 | `tools.loopDetection.warningThreshold`, `criticalThreshold` and `globalCircuitBreakerThreshold` are absent from the documented `tools.loopDetection` key list, which names only `enabled` | `entrypoint.sh` first `node -e` block | verify-locally |
| D6 | Writing whole-object `tools.exec = {...}` clobbers any operator-set sibling — `timeoutSeconds`, `applyPatch`, `grantExpiryDays` | `entrypoint.sh` first `node -e` block | doc-verified |

D4 and D5 are the *verify-locally* rows, and they carry the check that would falsify them:

```bash
docker run --rm --entrypoint openclaw <image> config schema > schema.json
jq '.. | objects | select(has("properties")) | .properties | keys' schema.json | grep -n security
docker exec hermes openclaw config validate --json
```

**Run that before anything else in this spec.** If either key is genuinely unrecognised, 004's
gate will refuse to start a container that previously worked, and this stops being a tidy-up.

## User Stories

- As the operator, I want a key that upstream has renamed to fail when the image is built, not
  when the container restarts three months later.
- As the operator, I want a setting I tuned by hand to survive a restart, rather than being
  replaced by a whole-object assignment.
- As the maintainer, I want adding a configuration key to be a one-line call that validates
  itself, so that the next key cannot be added wrongly.

## Acceptance Criteria

- [ ] Given the entrypoint configures the container, when it sets a key, then it does so
      through a path-based setter that validates against the live schema.
- [ ] Given a key upstream no longer recognises, when the container starts, then the failure
      names that key and no partially-written config is left behind.
- [ ] Given an operator has set a sibling of a key the entrypoint writes, when the container
      restarts, then the sibling survives.
- [ ] Given `exec-approvals.json`, then either the container stops writing it and the exec
      policy is set where the policy now lives, or the file is shown still to be honoured.
- [ ] Given `tools.exec.security` and the three `loopDetection` thresholds, then each is either
      confirmed against `openclaw config schema` or removed.

## Structural Impact

### Runtime configuration (`roles/openclaw/files/entrypoint.sh`)
The first `node -e` block, which is 004's region — so this lands after 004 and inherits it.

### Documentation
`README.md` § Startup validation loses the "roughly fifteen keys written by hand" framing once
they are not.

## Dependencies

- **004** supplies the validate gate and the phase ordering this refactor sits inside.

## Open Questions

1. **Does `openclaw config set` accept every shape this entrypoint needs?** The heartbeat
   prompt is a multi-line string containing quotes; `tools.deny` is an array; `commands.
   ownerAllowFrom` is an array of strings. If the setter cannot express one of them, that key
   stays in a `node -e` block and the class is only mostly dissolved.
2. **Is the config file writable while the gateway is not running?** Every call in the current
   block happens before `exec`. If the setters require a running gateway, the whole sequence
   moves after it, which changes what a failure means.
