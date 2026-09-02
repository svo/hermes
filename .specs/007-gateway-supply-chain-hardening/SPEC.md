# Feature: Gateway and supply-chain hardening

> Adapted from the `specify` skill — see [`.specs/README.md`](../README.md) § Template adaptation.

## Overview

Three posture problems that share a theme: the deployment is broader, less pinned, and less
protected than the documented usage requires.

**The gateway binds to LAN with no auth configured.** Upstream is explicit that non-loopback
binds require an explicit auth path and that the gateway will otherwise refuse to bind. The
README publishes only `127.0.0.1:3000:3000`, so `lan` buys nothing and costs reachability
from every other container on the Docker network.

**Nothing is pinned.** `openclaw` installs with `state: latest`, `gog` resolves
`releases/latest` at build time, the workflows rebuild weekly on a cron, images publish as
`:latest`, and the README recommends `--pull always`. Combined with OpenClaw's strict config
schemas — where an unknown key is a hard validation error, not an ignored one — this is an
untested auto-upgrade path straight to production. The git history records this failing
repeatedly: two reverts, `Removing bad configuration option`, and two commits removing an
invalid timezone field.

**Secrets are written world-readable.** The Anthropic key, both Slack tokens, and the
Telegram bot token land in `openclaw.json` at default `0644` on a host bind mount.

## Source Findings

| ID | Claim | Anchor | Confidence |
|---|---|---|---|
| A3a | Gateway binds `lan` at onboarding and at exec | `entrypoint.sh:12`, `:287` | internal-contradiction |
| A3b | `gateway.auth` is never configured | `entrypoint.sh:30-75` | internal-contradiction |
| A3c | Non-loopback binds require an explicit auth path or the gateway refuses to bind | upstream `docs/gateway/troubleshooting.md` | doc-verified |
| A3d | Documented port mapping is loopback-only, making `lan` unnecessary | `README.md:56` | internal-contradiction |
| D1a | `openclaw` installed with `state: latest` | `roles/openclaw/tasks/main.yml:2-6` | internal-contradiction |
| D1b | `gog` resolved from `releases/latest` at build time | `roles/openclaw/tasks/main.yml:8-12` | internal-contradiction |
| D1c | Weekly scheduled rebuilds publish `:latest` | `.github/workflows/*.yml:14-15` | internal-contradiction |
| D1d | `de52c54` reverted the earlier pinning in `abc6127` | git history | execution-verified |
| D2 | Strict schemas make an unknown key a hard failure | upstream `zod-schema.agent-runtime.ts` | doc-verified |
| D3a | `curl \| tar` with no checksum or signature | `roles/openclaw/tasks/main.yml:17-18` | internal-contradiction |
| D3b | fastText zip with no checksum | `roles/fasttext/tasks/main.yml:12` | internal-contradiction |
| D4 | Anonymous `api.github.com` call, 60/hr shared runner limit, no retry | `roles/openclaw/tasks/main.yml:9-12` | doc-verified |
| D5 | Secrets written at default `0644` on a bind mount | `entrypoint.sh:74`, `:244`, `:260`, `:21` | execution-verified |

**Falsify before implementing:** `openclaw config get gateway.bind`,
`openclaw config get gateway.auth.mode`, `openclaw config get gateway.auth.token`.
These reveal whether onboarding silently generated a token.

## User Stories

- As the operator, I want the gateway reachable only where I publish it, so that other
  containers on the Docker network cannot reach an unauthenticated agent API.
- As the operator, I want to know which OpenClaw version my image contains, so that I can
  reproduce a build and roll back a bad one.
- As the operator, I want upgrades to be a deliberate, tested change rather than a Thursday
  cron, so that a schema change does not brick every running container.
- As the operator, I want credentials on disk readable only by their owner.
- As the maintainer, I want downloaded artifacts verified, so that a compromised release
  does not silently enter the image.
- As the maintainer, I want builds not to fail on a shared GitHub API rate limit.

## Acceptance Criteria

- [ ] Given the container starts, then the gateway binds loopback and
      `openclaw config get gateway.bind` returns `loopback`.
- [ ] Given loopback binding, when the documented `docker run` is used, then Telegram, Slack,
      and the published port all still work.
- [ ] Given a non-loopback bind is explicitly requested, when no auth is configured, then
      startup fails with a clear message rather than binding unauthenticated.
- [ ] Given the role installs OpenClaw, then it installs an explicit pinned version.
- [ ] Given the role installs gog, then it installs an explicit pinned version and verifies
      a checksum.
- [ ] Given the fastText download, then its checksum is verified.
- [ ] Given a pinned build, when the same commit is rebuilt, then the same tool versions are
      installed.
- [ ] Given the config is written, then `openclaw.json`, `exec-approvals.json`, and any
      service-account key are mode `0600`.
- [ ] Given the GitHub API is rate-limited, when the build runs, then it retries with
      backoff and reports clearly if it still fails.
- [ ] Given a version bump, then it is a reviewable diff in the repository.

## Structural Impact

### Provisioning (`roles/openclaw/tasks/main.yml`, `roles/fasttext/tasks/main.yml`)
- Pin the `openclaw` npm version; replace `state: latest`.
- Pin the gog release; verify a checksum; add retry to the API call, or remove the call
  entirely once the version is pinned.
- Verify the fastText archive checksum.

### Runtime configuration (`roles/openclaw/files/entrypoint.sh`)
Owned regions: `:12` (`--gateway-bind`), `:287` (`--bind`), and an appended permissions step.
- Change both to `loopback`; expose the choice through an environment variable that requires
  auth when non-loopback.
- `chmod 0600` on the config and approvals files after every write.
- **Do not** touch `:1-99` (004), `:248-262` (002), or `:264-285` (003).

### Image & CI
- Document the upgrade procedure. Consider decoupling the weekly rebuild (security patches
  for the base image) from tool version bumps (deliberate, reviewed).

### Documentation
- `README.md` — the bind/auth model, the pinned versions, and how to upgrade.

## Configuration Contract

| Variable | Required | Purpose |
|---|---|---|
| `HERMES_GATEWAY_BIND` | No (default `loopback`) | gateway bind interface |
| `HERMES_GATEWAY_TOKEN` | With a non-loopback bind | `gateway.auth.token` |

New Ansible variables for pinned versions of `openclaw`, `gog`, and `fastText`, each with a
checksum where the artifact is downloaded directly.

## Operability

- Startup logs the bind interface and whether auth is configured — never the token.
- `openclaw --version` inside the image reports the pinned version.
- Verification: `openclaw config get gateway.bind`, `openclaw gateway status`,
  `stat -c '%a' /root/.openclaw/openclaw.json` → `600`.

## Dependencies

None hard. Pinning makes **006**'s CI deterministic, so landing 007's pinning before 006
reduces unrelated churn in the new gate.

## Open Questions

1. **Did onboarding generate a token?** Run the three `config get` probes above first. If a
   token exists, A3 is "unmanaged credential" rather than "unauthenticated bind" — same fix,
   different severity, and worth stating accurately.
2. **Does any deployment rely on LAN binding?** If the gateway is reached from another
   container or host, loopback breaks it. Recommendation: default `loopback`, keep the
   override, require a token with it. Confirm no current deployment depends on `lan`.
3. **Pin exactly, or to a minor range?** Exact is reproducible but needs manual bumps; a
   range keeps patches flowing but reintroduces the untested-upgrade risk. Recommendation:
   exact, with a scheduled bump PR.
4. **Split the weekly rebuild?** Base-image security patches are worth having weekly; tool
   version bumps are not. Splitting keeps both properties. Needs a decision.
5. **Secret storage.** `0600` is a floor, not a solution — the agent runs as root and can
   read every file in the container. Docker secrets or a SecretRef indirection would be
   stronger. Out of scope here; track separately.
