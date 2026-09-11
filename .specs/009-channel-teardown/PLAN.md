# Plan: Channel teardown

> Adapted from the `plan` skill — see [`.specs/README.md`](../README.md) § Template adaptation.
> Spec: [`SPEC.md`](SPEC.md)

## The probe, first

Both of `SPEC.md`'s Open Questions turn on one thing the spec could not know: whether a channel
block that has had its token deleted is still a *legal* channel block. If `botToken` is required,
"disable and strip the token" produces a config the phase 3 gate refuses, and a teardown becomes a
brick — the exact failure 004 exists to end, arriving through the door 009 opens.

So it was run first, against `openclaw@2026.9.2` — the version
`roles/openclaw/defaults/main.yml` pins, so the schema consulted is the one the container loads.

**`botToken` is not required, and the torn-down block validates.**

```
channels.telegram  required: ["dmPolicy","groupPolicy"]          additionalProperties: false
channels.slack     required: ["dmPolicy","groupPolicy","postAs","mode",
                              "webhookPath","userTokenReadOnly"]  additionalProperties: false
```

Neither list names a credential. `botToken`, `appToken`, `userToken`, `signingSecret` and
`tokenFile` are all optional, so a channel may exist without one. The end-to-end check, against a
config shaped exactly as this entrypoint writes it:

```
$ printf '{"channels":{"telegram":{"enabled":false,"botToken":null}}}' \
    | openclaw config patch --stdin
Applied 2 config update(s). Restart the gateway to apply.

$ openclaw config get channels.telegram
{ "enabled": false, "dmPolicy": "allowlist", "allowFrom": ["111","222"],
  "groups": { "*": { "requireMention": true } } }

$ grep -c 'TELEGRAM-SECRET' ~/.openclaw/openclaw.json
0

$ openclaw config validate
Config valid: ~/.openclaw/openclaw.json
```

The same for Slack with both credentials nulled at once — `botToken` and `appToken` gone,
`dmPolicy`, `allowFrom`, `groupPolicy` and the `channels` map still there, still valid. The
required keys the entrypoint never writes (`postAs`, `webhookPath`, `userTokenReadOnly`) are
satisfied by runtime defaults, which is why the config validates today and keeps validating after
a teardown.

### Four things the probe settled that the spec did not raise

**1. An unguarded patch creates the empty block acceptance criterion 5 forbids.** Against a
container that never configured Telegram:

```
$ printf '{"channels":{"telegram":{"enabled":false,"botToken":null}}}' \
    | openclaw config patch --stdin
Applied 2 config update(s).
$ openclaw config get channels
{ "telegram": { "enabled": false } }
$ openclaw config validate
Config valid: ~/.openclaw/openclaw.json
```

It validates. So nothing downstream catches it, and the guard on "is this channel actually in the
persisted config" is the only thing standing between this spec and the criterion that forbids it.
That is why the guard is a behaviour with its own cases rather than an implementation detail.

**2. `config patch` is not idempotent, so the guard is what makes teardown a one-off.** Re-applying
the identical teardown patch to an already-torn-down config answers
`Applied 2 config update(s)` and exits zero — it counts the paths in the payload, not the paths
that changed. Without a guard that asks whether there is anything left to tear down, every restart
for the rest of the volume's life would re-patch and re-print the teardown line, and acceptance
criterion 6's "one line" would become one line per start, for ever.

**3. A rejected patch exits 1 and writes nothing.** `Config validation failed: channels.telegram:
invalid config: must not have additional properties: "nopeKey"`, exit 1, the block on disk
unchanged. Teardown can therefore fail closed without a separate rollback.

**4. `config get` reports the *effective* config, not the authored one.** It merges runtime
defaults in — `groupPolicy: "allowlist"` comes back for a Telegram block that does not author it,
and `postAs: "bot"` for a Slack block that does not. The teardown guard must not be built on it:
the question is what is *persisted in `openclaw.json`*, which is what acceptance criterion 2 names
and what a copy of the volume carries. The guard reads the authored file.

**5. The setter keeps backups, and the backups keep the token.** This one was not found by the
probe. It was found by an adversarial review *after* the change was written and its suite was
green, which is the only reason it is in this document rather than in the repository.

`openclaw config patch` copies the old configuration to `~/.openclaw/openclaw.json.bak` before
writing the new one, and rotates five generations — `.bak` through `.bak.4`:

```
$ ls ~/.openclaw/ | grep bak
openclaw.json.bak  openclaw.json.bak.1  openclaw.json.bak.2  openclaw.json.bak.3  openclaw.json.bak.4
$ grep -l TOKEN-MARKER ~/.openclaw/openclaw.json.bak*
   ... all five
```

For every other write in this file that costs nothing: the backup holds the same credentials the
live config holds. This write is the exception, and in the direction that matters. SPEC's second
user story is *"a token I have removed to stop being stored, so that a copy of the volume does not
carry a credential I thought was gone"* — and the command that satisfies the first story writes
that credential into a file beside the one it removed it from. `openclaw.json` clean, volume dirty.

Acceptance criterion 2 says "anywhere in `openclaw.json`", so a suite reading the criterion
literally goes green over this. It did. The teardown now sweeps `openclaw.json.bak*` after a
successful patch, the criterion is asserted against **every file under `$HOME`** instead, and the
stub models the backups so the assertion is not vacuous — which it was, at first, because a stub
that does not write backups cannot show you a sweep that is missing.

Deleted rather than rewritten: there is no rollback point here that does not reintroduce a revoked
credential. Removing them was probed too — `config validate` and the next `config patch` both work
normally afterwards.

### Both Open Questions are answered

**Open Question 1 — disable, or delete the whole block?** *Disable, and strip the credentials the
container wrote.* The acceptance criteria already say so and the probe says it is legal:
criterion 1 asks for the channel to be **disabled**, criterion 2 for the **token** to be gone, and
criterion 6 for a line naming the channel that was **disabled**. Deleting the block satisfies 2 by
accident and reads oddly against 1 and 6.

**One reason given for this answer turned out to be wrong, and it is corrected here rather than
quietly kept.** The claim was that disabling makes re-adding a token "one `-e` rather than two".
It is two either way. Phase 1 requires `TELEGRAM_ALLOW_FROM` whenever `TELEGRAM_BOT_TOKEN` is set
— a rule about the *environment*, not about what survived in the config — so restoring the token
alone makes the container refuse to start. And the channel blocks rewrite the whole block from the
environment on every start, so a restored Slack channel that omits `SLACK_ALLOW_CHANNELS` comes
back with an empty `channels` map and `groupPolicy: disabled` whether the old one was kept or not.
Both were reproduced against the real entrypoint.

So what disabling actually buys is narrower than the first draft of this plan claimed, and it is
still enough: the criteria say *disabled* three times between them; a disabled block remains a
record of who was allowed, which a deleted one is not; and it is the smaller change of the two,
which matters when the thing being changed is a file the operator did not write. The README says
the same thing, and no longer promises the recovery that does not exist.

What is stripped is what this container wrote: `botToken` for Telegram, `botToken` **and**
`appToken` for Slack. Slack having two credentials is the half of criterion 2 that a
Telegram-shaped fix would miss. An operator's own `userToken`, `signingSecret` or `tokenFile` is
left alone — this container never wrote one, and deleting a key it does not own is not teardown.

**Open Question 2 — does teardown belong in the entrypoint at all?** *Yes, and with no opt-out
variable.* The objection is that a `docker run` which forgets a `-e` silently disables a channel.
Three things answer it:

- The **silently** is what criterion 6 removes. The container says which channel it disabled and
  which variable is no longer set.
- Recovery is putting back the variables you had. That is two or three of them rather than one —
  see the correction above — but they are the same ones that were already in the `docker run` that
  worked, so recovery is restoring a command line rather than reconstructing a configuration.
- A `HERMES_CHANNEL_TEARDOWN` opt-out would have to default to *on* for the spec to mean anything,
  so it protects nobody the first time they hit the surprise — only the second. It buys one more
  variable, one more branch, one more README row, and it makes channels the single part of this
  config that is not a function of the environment. 007 already writes `gateway.bind` on every
  start for exactly the reason 009 writes channels on every start: a config written under one set
  of flags must not keep describing them after the flags change.

## Implementation Strategy

**One block, one commit.** The teardown is a single stretch of `entrypoint.sh` with its own suite;
there is no intermediate state worth committing, and unlike 008 there is no second finding riding
along.

The block does three things in order, and the order is the design:

1. **Plan** — one `node -e` reads the *authored* `openclaw.json`, compares it against the
   environment, and prints the name of each channel that is configured in the file but has lost
   its token. It writes nothing. On a container with no config, or no channels, or every token
   still set, it prints nothing and the rest of the block does not run.
2. **Patch** — the names are turned into one `openclaw config patch --stdin` payload of `false`
   and `null`. One patch, not one per channel: if both channels are being torn down they should
   both be torn down or neither, and a rejected patch writes nothing.
3. **Sweep** — delete the rotating `openclaw.json.bak*` backups the setter just wrote, because on
   this one write they hold a credential the operator revoked. See probe result 5.
4. **Say so** — one line per channel, printed *after* the patch succeeds, never before. A teardown
   line printed ahead of the write is a line that can be a lie.

Reading the config in step 1 is not the class 008 dissolved. 008 was about *writing* keys by hand
into a strict schema, and the write here goes through the validating setter like every other write
in phase 2. What step 1 does is ask the file a question, and the file is the only thing that knows
the answer.

## Layer Changes

### Runtime configuration (`roles/openclaw/files/entrypoint.sh`)

Owned region: a new channel-teardown block, placed immediately after the Slack block and before
007's gateway bind/auth block. `.specs/README.md` § Shared-file ownership already reserved this
stretch and said which end of it: *"land it above them: teardown has to run before the permissions
step, not after it."*

Nothing above it changes. 002's Slack block, the Telegram block, 004's phases and 008's payload
builder are all untouched — this is one new block between two existing ones, which is why neither
002 nor 004 had to be reopened.

Why *after* the channel blocks: they write directly to the file, so a teardown that read the
config before them would be judging a stale one. Why *before* 007's permissions step: the patch
rewrites `openclaw.json`, and every file this container creates should reach the `chmod 0600`
sweep rather than be written after it. (`config patch` was probed and leaves the file at 0600 —
008 found it even tightens a 0644 file — but ordering that does not depend on that is better than
ordering that does.)

### Documentation

`README.md` — both § *Access control* sections gain the sentence SPEC § Structural Impact asks
for, saying what removing the token does. Neither section is otherwise touched.

## Configuration Contract

| In | Out |
|---|---|
| `TELEGRAM_BOT_TOKEN` absent, `channels.telegram` present in the persisted config | `channels.telegram.enabled: false`; `botToken` deleted; `dmPolicy`, `allowFrom` and `groups` left as they are |
| `SLACK_BOT_TOKEN` absent, `channels.slack` present | `channels.slack.enabled: false`; `botToken` **and** `appToken` deleted; `dmPolicy`, `allowFrom`, `groupPolicy` and `channels` left as they are |
| either token present | nothing — the channel block above wrote it this start |
| channel absent from the persisted config | nothing, and no block is created |
| a channel already torn down | nothing, and nothing is printed |

No new environment variable — see Open Question 2. This spec adds no key to the config; it removes
two and sets one that the channel blocks already write.

## The guard, stated exactly

A channel is torn down when **all three** hold:

1. its `*_BOT_TOKEN` is unset or empty in this start's environment, **and**
2. `channels.<name>` is an object in the persisted `openclaw.json`, **and**
3. that object still carries one of the credential keys this container writes.

Clause 2 is acceptance criterion 5, and the probe shows it is load-bearing rather than defensive:
without it the patch creates `{"telegram":{"enabled":false}}` on a container that never had
Telegram, and the validator accepts it. It is also what keeps clause 3 from throwing —
`hasOwnProperty.call` raises a TypeError on `undefined`, which is what an absent channel is on
every container that configures one of these two and not the other.

Clause 3 is the idempotence guard and the ownership guard at once.

*Idempotence*, because the probe shows `config patch` will happily re-apply the same teardown for
ever and report two updates each time, so the entrypoint — not the setter — is what has to notice
there is nothing left to do.

*Ownership*, because a channel block in this file is not necessarily this container's. This clause
was first written as *"still enabled, **or** still holding a credential"*, and an adversarial
review of the change showed what that costs: an operator who configures Telegram themselves with
`tokenFile` — a key this container never writes and never reads — has their working channel
disabled on the next start, and is told a token was removed that nothing here ever touched.
Reproduced, then narrowed to *"still holding one of our credentials"*, which is strictly smaller
and still covers every case the criteria name: a container configured by this entrypoint always has
`botToken` in the file.

`enabled` is deliberately not consulted. A block an operator disabled by hand while leaving the
token in it has had half a teardown, and the half that matters is the other one — that case is
unchanged by the narrowing, because the token is still there to find.

## Task List

1. [x] **run the probe** — is a channel block legal without its token, and does the torn-down
       config still validate? Recorded above: yes, both, against `openclaw@2026.9.2`.
2. [ ] runtime-config: the teardown planner — one `node -e` that reads the authored config and the
       environment and names the channels to tear down.
3. [ ] runtime-config: the patch — one `openclaw config patch --stdin` of `enabled: false` and
       `null` credentials, failing closed, its output redacted.
4. [ ] runtime-config: sweep `openclaw.json.bak*` after a successful teardown, so the revoked
       credential leaves the volume rather than only the live config.
5. [ ] runtime-config: the log line — one per channel, after the patch, naming the channel and the
       variable that is no longer set.
6. [ ] tests: a new `009/tests` suite — the six acceptance criteria, plus idempotence, plus the
       allowlist surviving, plus a start that still reaches the gateway.
7. [ ] tests: teach the stub the backups the real setter keeps, so the sweep can be asserted at all.
8. [ ] tests: `mutation-check`, in this repository's shape — every case shown failing against a
       deliberately broken entrypoint.
9. [ ] docs: `README.md` — both § *Access control* sections.
10. [ ] docs: `.specs/README.md` — 009's ownership row, and the removal of the "009 is not planned
        yet" line.

## Testing Strategy

No test framework exists; verification is config-level, as it is for every spec here. The suite is
008's harness — the real `entrypoint.sh` against a stub `openclaw`, a private `HOME` per case, and
a `--home` that lets one case run two starts over one volume.

That last part is most of this spec. **Every criterion here is a statement about a restart**, and a
single start can never tell you which way it went: the container has to be configured with a token
first, and then started again without one. `seed_config` and `run_entrypoint --home` already exist
for exactly that, from 008.

- **Criterion 1** — configure Telegram, restart without the token, assert
  `channels.telegram.enabled` is `false`. Then the same for Slack.
- **Criterion 2** — the same restart, asserted twice. First against the **raw bytes of
  `openclaw.json`** rather than a dotted-path lookup, because the criterion says *anywhere in the
  file* and a path lookup would pass while a copy of the token sat under some other key. Then
  against **every file under `$HOME`**, because the user story behind the criterion is about the
  volume, and the setter's rotating backups are on the volume. Slack's cases assert both
  credentials throughout.
- **Criterion 3** — configure both, restart with only one token, assert the surviving channel's
  `enabled`, its token and its allowlist are all untouched. Run in both directions, because a
  teardown that hardcoded the wrong channel name would pass one of them.
- **Criterion 4** — configure, restart *with* the token, assert nothing moved and nothing was said.
- **Criterion 5** — a container that never had the channel: assert `channels.telegram` is `absent`
  after a start with no Telegram token. This is the case the probe proved can fail silently.
- **Criterion 6** — assert the line, that it names the channel, and that it does **not** carry the
  token. Also asserted on the payload: `patch_get channels.telegram.botToken` must read `null`
  rather than `absent`, which is the difference between "asked for it to be deleted" and "did not
  mention it".
- **Idempotence** — three starts: configured, torn down, started again. The third must not print a
  teardown line and must not issue a second teardown patch. Counted through the argv log, because
  the config looks identical either way.
- **The allowlist survives** — the whole reason Open Question 1 was answered *disable*.
- **The container still starts** — `gateway_started`, and the phase 3 gate ran. A teardown that
  left a config the validator refuses would be a worse bug than the one being fixed, and this is
  the case that would have caught it if the probe had come out the other way.

Naming: `should_<behaviour>_when_<condition>`.

The suite is deliberately **not** wired into `bin/test`, following 002, 003, 004, 007 and 008 —
`.specs/008-config-via-cli/tests/README.md` § *Why this suite is not a `bin/test` check* gives the
reason, and it applies here unchanged. The gate still lints every file in it, because discovery is
by shebang rather than by extension.

## Operability Plan

- One line per torn-down channel, on stdout, in the file's existing vocabulary:
  `channels: telegram disabled and its token removed (TELEGRAM_BOT_TOKEN is not set).`
- Nothing at all when nothing is torn down. A start that changes nothing should say nothing;
  criterion 4 asserts that.
- The line is printed after the write succeeds, so it is never a claim about something that did not
  happen — the mistake 008 found in its own approvals block, where the exit code was reported
  instead of the outcome.
- Operator checks: `openclaw config get channels.telegram`, `openclaw config validate`, and
  `grep -c <token> ~/.openclaw/openclaw.json` for the criterion that matters most.

## Risks and Mitigations

- **Risk:** the teardown creates a channel block on a container that never had one — acceptance
  criterion 5, inverted. → **Not hypothetical: the probe did it.** An unguarded patch writes
  `{"telegram":{"enabled":false}}` and the validator accepts it, so nothing downstream would catch
  it. Clause 2 of the guard is the mitigation and it has its own case and its own mutation.
- **Risk:** the teardown repeats on every restart, printing its line for ever. → `config patch`
  reports `Applied 2 config update(s)` on a no-op re-patch, so the setter will not stop it. Clause
  3 of the guard does, and an explicit three-start case counts the patches rather than reading the
  config, because the config looks the same either way.
- **Risk:** the torn-down config is refused by the phase 3 gate, turning a teardown into a brick.
  → **Probed before anything was written**, which is why the probe is task 1. `botToken` is not a
  required key on either channel, and `openclaw config validate` accepts the stripped block for
  both. A case asserts the gate ran and the gateway started, so a future schema change that makes a
  credential required goes red here rather than in a running container.
- **Risk:** Slack is torn down as if it were Telegram, leaving `appToken` on the volume. → This is
  the asymmetry SPEC § Overview says neither 002 nor 004 could fix half of. Slack's credential list
  has two entries, criterion 2's Slack case asserts on the raw file for both, and a mutation drops
  `appToken` from the payload to prove the case notices.
- **Risk:** `redact_secrets` cannot mask the token being removed. It filters on the *environment*,
  and the whole premise of a teardown is that the variable is no longer set. → Real, and bounded:
  the payload this block sends contains no credential at all — only `false` and `null` — and a
  rejection quotes the payload. The other channel's tokens, if it still has any, are in the
  environment and are filtered normally. The output is passed through `redact_secrets` anyway, for
  the same reason every other command in phase 2 is: the next person to add something to this block
  should find the filter already there.
- **Risk:** a failed teardown lets the container start with the channel still live. → It exits 1.
  This is the one place where failing closed is unambiguous: the operator's intent was to revoke
  access, and a container that starts anyway keeps answering on a channel they believe is gone,
  holding a token they believe is deleted. A start that refuses is loud, and it does not serve the
  channel either.
- **Risk:** the planner reads a config that does not exist yet, or one that is not an object, and
  the start dies on an exception under `set -e`. → It is wrapped: an unreadable or unparseable file
  means "no channels to tear down", which is correct on a first-ever start and safe everywhere
  else. Phase 3's gate is what judges a corrupt config, and it is downstream of here.
- **Risk:** the guard is built on `openclaw config get` and reads defaults as authored values.
  → The probe found `config get` merges runtime defaults in, so this would be wrong in the
  direction that matters — it would make an unconfigured channel look configured. The planner reads
  the authored file. What pins it is `a channel block is created on a container that never
  configured one` — the mutation whose outcome is exactly what an effective-config read would
  produce — plus `the planner reads a file that is not the config`. A mutation that literally
  substituted `openclaw config get` was considered and dropped: the stub answers "unset" for an
  unauthored path, so it would demonstrate nothing here, and the hazard is recorded from the probe
  against the real CLI instead.
- **Risk:** a teardown of the last configured channel leaves `commands.ownerAllowFrom` naming an
  identity on a channel that is now disabled. → **Out of scope and recorded rather than fixed.**
  Those entries are user IDs, not credentials, so no acceptance criterion covers them, and the
  behaviour is 008's rather than this spec's: phase 1 stops deriving owner entries once the token
  is gone, the payload then omits `commands.ownerAllowFrom`, and a recursive merge leaves the
  previous value in place. It is listed under § Findings This Work Added.

- **Risk:** the token leaves `openclaw.json` and stays on the volume in something else.
  → **This happened, and the suite was green over it.** `config patch` keeps five rotating
  backups; the sweep removes them, and the criterion is now asserted volume-wide. The general
  lesson is worth more than the instance: a criterion written about one file is not a promise about
  the volume, and a setter is entitled to write files nobody asked it to.
- **Risk:** the stub is kinder than the real CLI, so the new assertion proves nothing.
  → It was, and it did not: against a stub that wrote no backups, **both** mutations for the sweep
  survived. The stub now writes and rotates them the way the real one does, and both are caught.
  This is the same discipline 008 recorded when a permissive stub let `--dry-run` through.
- **Risk:** the teardown fires on a channel block this container never wrote.
  → **Reproduced against the real entrypoint** with an operator-configured `tokenFile` channel, and
  fixed by narrowing clause 3 to "still holds one of our credentials". Two cases and a mutation pin
  it in both directions — the operator's channel is left alone, and their `userToken` and
  `signingSecret` survive a teardown of the channel beside them.
- **Risk:** this is read as "the credential is now unrecoverable". → It is not. `rm` unlinks; it
  does not overwrite the blocks, and the agent in this container runs as root and can read every
  file in it. This closes the copy an operator would find by looking, which is the finding, and it
  is a floor rather than a fix — the same thing 007 says about `chmod 0600`.

## Findings This Work Added

| ID | Claim | Anchor | Confidence | Status |
|---|---|---|---|---|
| A2g-a | An unguarded teardown patch **creates** `channels.<name>` on a container that never configured it, and `openclaw config validate` accepts the empty block — so acceptance criterion 5 has no backstop but the guard | `openclaw config patch` against a config with no channel block | execution-verified | **guarded here** — clause 2, with its own case and mutation |
| A2g-b | `openclaw config patch` counts the paths in the payload rather than the paths that changed, so a no-op re-patch reports `Applied 2 config update(s)` and exits zero | `openclaw config patch --stdin`, applied twice | execution-verified | **guarded here** — clause 3; the setter cannot make teardown a one-off, so the entrypoint does |
| A2g-c | `openclaw config get` returns the config with runtime defaults merged in — `groupPolicy` for a Telegram block that never authored one, `postAs` for a Slack block that never authored one | `openclaw config get channels` | execution-verified | **avoided here** — the guard reads the authored file. Worth knowing for any later block tempted to ask the CLI what is configured |
| B3d-a | Removing the last channel's token leaves `commands.ownerAllowFrom` naming an identity on a channel that no longer answers | `entrypoint.sh` payload builder, `commands.ownerAllowFrom` | internal-contradiction | **not fixed** — no criterion covers it and it is 008's merge behaviour rather than this block's. See § Risks |
| A2g-d | `openclaw config patch` keeps five rotating backups of the config beside it, so the setter that removes a revoked token writes it into `openclaw.json.bak` in the same breath. Criterion 2 is met and the user story behind it is not | `openclaw config patch`, `~/.openclaw/openclaw.json.bak*` | execution-verified | **fixed here** — swept after a successful teardown; asserted volume-wide rather than file-wide; the stub models the backups so the assertion is not vacuous |
| A2g-e | A guard of "configured, and no environment variable" tears down channel blocks this container never wrote — an operator's `tokenFile`-configured Telegram is disabled, and the log claims a token was removed that was never touched | `entrypoint.sh` teardown planner, clause 3 | execution-verified | **fixed here** — clause 3 narrowed to "still holds one of our credentials", which is both the idempotence guard and the ownership guard |
| A2g-f | Restoring a channel needs every variable it needed before, not just the token: phase 1 demands the allowlist from the *environment*, and the channel blocks rewrite the block from the environment on every start. Keeping the allowlist in the config does not shorten recovery | `entrypoint.sh` phase 1; the Telegram and Slack blocks | execution-verified | **documented** — it falsified a reason given for Open Question 1's answer, not the answer. README and § Open Questions corrected |
