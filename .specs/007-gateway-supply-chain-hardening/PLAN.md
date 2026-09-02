# Plan: Gateway and supply-chain hardening

> Adapted from the `plan` skill — see [`.specs/README.md`](../README.md) § Template adaptation.
> Spec: [`SPEC.md`](SPEC.md)

## Implementation Strategy

Three independent tracks that happen to share a theme. Land them as separate commits — they
have different risk profiles and different rollback stories.

**Track 1 — bind posture.** Start with the falsification probes. Whether onboarding
generated a `gateway.auth.token` changes the finding's severity but not the fix: the
documented deployment publishes `127.0.0.1:3000:3000`, so `lan` is strictly worse than
`loopback`. Make `loopback` the default, keep an override, and make the override *require*
a token so the insecure combination is unreachable rather than merely discouraged.

**Track 2 — pinning.** Lowest technical risk, highest stability payoff. Pinning also removes
the need for the anonymous GitHub API call (D4) entirely — with a pinned gog version there
is nothing to resolve at build time, so the rate-limit fragility disappears rather than
being retried around. That is the better fix and it falls out of the pin for free.

**Track 3 — permissions.** A `chmod 0600` after each write. Genuinely small, and worth
stating plainly: it is a floor, not a solution. The agent runs as root and can read every
file in the container, so `0600` protects against host-side and other-container access, not
against the agent itself. Do not describe this as fixing secret exposure.

The one sequencing note: land pinning before **006** if possible, so the new gate is not
absorbing unrelated version churn on its first runs.

## Layer Changes

### Provisioning (`roles/openclaw/tasks/main.yml`)
- Replace `state: latest` with an explicit `version:` from a role variable.
- Replace the `releases/latest` lookup with a pinned gog version variable; **delete** the
  `ansible.builtin.uri` task (D4 dissolves).
- Add checksum verification to the gog download. Prefer `get_url` with `checksum:` over
  `shell` + `curl | tar`, which also clears 006's `risky-shell-pipe` finding — coordinate
  with 006 task 3 so the fix is applied once, not twice.

### Provisioning (`roles/fasttext/tasks/main.yml`)
- Add `checksum:` to the `unarchive` task for the v0.9.2 zip.

### Runtime configuration (`roles/openclaw/files/entrypoint.sh`)
Owned regions: `:12`, `:287`, plus an appended permissions step.

- `:12` — `--gateway-bind "${HERMES_GATEWAY_BIND:-loopback}"`.
- `:287` — `--bind "${HERMES_GATEWAY_BIND:-loopback}"`.
- When `HERMES_GATEWAY_BIND` is not `loopback`, require `HERMES_GATEWAY_TOKEN` and set
  `gateway.auth.mode = "token"` / `gateway.auth.token`. Missing token with a non-loopback
  bind is a startup failure. Register this rule with **004**'s validation block rather than
  adding a second validation site.
- After each config write, `chmod 0600` on `openclaw.json` and `exec-approvals.json`; also
  the service-account key path when `GOG_SERVICE_ACCOUNT_KEY` is set.

### Image & CI
- Document the upgrade procedure in the README.
- Per SPEC Open Question 4, consider splitting the weekly cron: keep the base-image rebuild,
  move tool bumps to a reviewed PR.

### Documentation
- `README.md` — bind/auth model, `HERMES_GATEWAY_BIND` and `HERMES_GATEWAY_TOKEN` rows,
  pinned versions, upgrade procedure, and a note that `0600` does not protect against the
  agent itself.

## Configuration Contract

| In | Out |
|---|---|
| `HERMES_GATEWAY_BIND` (default `loopback`) | onboarding and gateway bind flags |
| `HERMES_GATEWAY_TOKEN` (required when bind ≠ loopback) | `gateway.auth.mode`, `gateway.auth.token` |
| role vars: `openclaw_version`, `gog_version`, `gog_checksum`, `fasttext_checksum` | pinned, verified installs |
| — | `0600` on config, approvals, and service-account key |

## Task List

1. [ ] runtime-config: **run the probes** — `openclaw config get gateway.bind`,
       `gateway.auth.mode`, `gateway.auth.token`. Record the output in the commit message
       (SPEC Open Question 1).
2. [ ] runtime-config: default both bind flags to `loopback` via `HERMES_GATEWAY_BIND`.
3. [ ] runtime-config: require `HERMES_GATEWAY_TOKEN` for non-loopback binds and set
       `gateway.auth`; register the rule with 004's validation block.
4. [ ] runtime-config: `chmod 0600` after each write.
5. [ ] provisioning: pin `openclaw` to an explicit version.
6. [ ] provisioning: pin gog, add a checksum, delete the GitHub API task.
7. [ ] provisioning: add the fastText checksum.
8. [ ] provisioning: convert the gog install from `shell` + `curl | tar` to `get_url` +
       `unarchive` — coordinate with 006 task 3.
9. [ ] tests: end-to-end on loopback — Telegram, Slack, and the published port all work.
10. [ ] tests: non-loopback without a token fails at startup with a named error.
11. [ ] tests: reproducibility — build the same commit twice, assert identical tool versions.
12. [ ] docs: README bind/auth model, new variables, upgrade procedure, `0600` caveat.

## Testing Strategy

No test framework exists; verification is config-level and build-level.

- **Probe-first** (task 1) — establishes the real starting state before changing it. The
  finding's severity depends on the answer, and the commit message should record it.
- **Bind assertions** — `openclaw config get gateway.bind` → `loopback`;
  `openclaw gateway status` reports running; the published port still responds from the host.
- **Negative bind** — `HERMES_GATEWAY_BIND=lan` with no token must fail at startup. Assert
  the exit code and the message; assert the gateway never binds.
- **Permission assertions** — `stat -c '%a'` returns `600` for all three paths, including
  after a restart (the write path runs every start).
- **Channel regression** — Telegram and Slack use outbound connections and Socket Mode, so
  loopback should not affect them. Assert explicitly rather than assuming; this is the most
  likely way the change breaks something.
- **Reproducibility** — two builds of one commit, compare `openclaw --version` and
  `gog --version`.
- **Checksum failure** — corrupt an expected checksum, assert the build fails rather than
  installing.
- Naming: `should_<behaviour>_when_<condition>`.

## Operability Plan

- One startup line: `gateway: bind=loopback auth=none` or `bind=lan auth=token`. Never the
  token value.
- `openclaw --version` and `gog --version` reflect the pinned values.
- Operator checks: `openclaw config get gateway.bind`,
  `stat -c '%a' /root/.openclaw/openclaw.json`.

## Risks and Mitigations

- **Risk:** loopback breaks a deployment that reaches the gateway from another container.
  → **Mitigation:** the override exists; SPEC Open Question 2 confirms no current dependency
  before landing. This is the change most likely to surprise someone.
- **Risk:** pinning strands the deployment on a version with a known bug.
  → **Mitigation:** bumping is a one-line reviewable diff; add a scheduled bump PR so
  pinning does not become neglect.
- **Risk:** the pinned gog version's release asset naming differs across architectures.
  → **Mitigation:** the existing `regex_replace` architecture mapping is retained and tested
  on both `amd64` and `arm64` before the API task is deleted.
- **Risk:** deleting the API task loses the ability to track new releases.
  → **Mitigation:** intended. Discovery moves to a reviewed PR, which is the point.
- **Risk:** `0600` is read as "secrets are now safe". → **Mitigation:** state the limitation
  in the README and in the commit message. The agent runs as root; this protects the host
  side only.
- **Risk:** requiring a token for non-loopback binds breaks an existing LAN deployment on
  upgrade. → **Mitigation:** deliberate; the error names the variable and the fix. Release
  note.
- **Risk:** track 3 collides with 004's config-writing changes. → **Mitigation:** region
  ownership — 007 appends a permissions step after the writes; it does not alter them.
