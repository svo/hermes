# 003 checks

Verification for [SPEC.md](../SPEC.md). No image, no credentials, no Anthropic key — the
real `entrypoint.sh` runs against a stub `openclaw` on `PATH`, and the cases read the
automation store that stub keeps.

```bash
.specs/003-cron-registration-via-cli/tests/run
```

| File | What it is |
|---|---|
| `run` | Entry point. Runs every check, accumulating failures rather than stopping at the first. |
| `harness.sh` | Shared assertions and the hermetic runner. Sourced, not run. |
| `registration-test` | The accepted paths — what lands in the automation store, and what a restart does not do a second time. |
| `failure-test` | The rejected and failing ones — exit status, log line, and that the gateway starts anyway. |
| `mutation-check` | Sensitivity check. Not part of `run`; see below. |
| `stub-openclaw` | Fake `openclaw`: `onboard`, `gateway` (which also records the `GOG_ACCOUNT` it was started with), `gateway health`, `automations list`, `automations create`, `automations remove`. |

Fifty-one cases: 32 in `registration-test`, 19 in `failure-test`. 011 changed nine of them,
and folded two into one, when the registrar began declaring the briefing — see [011's PLAN](../../011-briefing-converges/PLAN.md)
§ Testing Strategy, "003's cases that invert". Ten were added, and two changed, when the
briefing's own `gog` commands turned out never to have run — see
[The briefing's `gog` commands](#the-briefings-gog-commands).

## Why not a container

`PLAN.md` § Testing Strategy specifies container-level verification — `docker restart`,
`docker exec hermes openclaw cron list`. That needs the image and an Anthropic API key, so it
is not something a check can do on its own, and two of the plan's tasks (the premise test and
the `operator.admin` probe) can only be answered that way. Those stay manual; see
[SPEC.md](../SPEC.md) § Open Questions for what is still unanswered.

What these cases assert is the same behaviour by a shorter route. The entrypoint is the thing
under test either way; only `openclaw` is replaced. Each run gets a private `HOME` and an
`env -i` environment carrying just the variables the entrypoint requires, so no persisted
config or ambient variable carries between cases. A case that needs to model a config volume
surviving a restart passes the same store — and the same `HOME` — to several runs.

## Waiting for a detached registrar

The registrar is forked immediately before `exec openclaw gateway`, so it outlives the
entrypoint process. It also inherits that process's stdout and stderr, which is how its
output reaches `docker logs` — and, here, how the harness sees it: it keeps writing to the
run's capture files after the entrypoint is gone.

Every terminal path of the registrar emits exactly one line, so waiting for one is waiting
for the registrar to finish:

| Line | Path |
|---|---|
| `cron: registered morning-briefing <id>` | created |
| `cron: updated morning-briefing <id>` | converged onto a changed environment |
| `cron: morning-briefing unchanged (<id>)` | already matched; nothing written |
| `cron: declared morning-briefing <id>; outcome unavailable` | landed, but `create`'s output did not parse |
| `cron: giving up after <n> attempts; briefing not scheduled (<why>)` | gave up, with no briefing listed and nothing declared |
| `cron: giving up after <n> attempts; briefing left as it was (<why>)` | gave up, with a briefing listed, keyed or not |
| `cron: giving up after <n> attempts; briefing declared but not confirmed (<why>)` | gave up after create said yes and no listing showed the key |

`cron: registration attempt <n>/<max> failed: <error>` is not terminal — it is the per-attempt
line, and more follow. Nor are 011's adoption lines, `cron: replaced unkeyed …` and
`cron: could not remove unkeyed …`. `cron: morning-briefing already registered (<id>)` was 003's
and is retired: it described presence, which is no longer the question.

A run that exits non-zero never reached the fork, so the harness does not wait for it.

## The stub

`stub-openclaw` keeps a JSON array of automations and appends to it on `create`, so the
questions the spec actually asks — *how many* `morning-briefing` jobs are there after five
starts, and *what* is in the one that exists — are answered from the store rather than from
a log line.

Two of its behaviours are deliberate rather than convenient:

- **`create` rejects a flag it does not know.** Upstream publishes no complete flag list for
  `automations create`, and two of its published lists each omit flags the other has. A
  registrar must therefore not invent one. A speculative `--json` or `--deliver` fails here
  the way it would fail against the real binary, rather than being quietly accepted.
- **`list` hides disabled jobs unless `--all` is passed.** That is doc-verified upstream
  behaviour, and it is the reason `should_find_the_briefing_when_it_is_disabled` exists: a
  registrar that omitted `--all` would read a disabled briefing as absent and register a
  second one.

The switches the cases drive it with are listed at the top of `stub-openclaw`.

### The declared CLI

The stub also models what 011 needs: `create --declaration-key` as an upsert by key,
`--exact`, `--disabled`, `remove <id>`, and the refusals. It follows what 011's probe recorded
against the pinned version ([011 PLAN](../../011-briefing-converges/PLAN.md) § The probe):

- `list --json` prints the `{ "jobs": [ … ] }` envelope by default, and a row carries
  `declarationKey` only when it has one.
- Every create warns on stderr that no `--agent` was given.
- A job stored with no stagger writes, and reports `updated: true`, on its first unchanged
  declaration in each run. That is B2, the upstream defect `--exact` avoids.
- `writes` in the store directory gets one line per real write, so "nothing was written" can
  be counted.

A refused create prints the `--agent` warning and then the refusal on stderr, and the refusal
again as JSON on stdout. The registrar takes its failure reason from the JSON, which is why
`should_keep_a_multi_line_error_on_one_log_line` still reads exactly the stub's message.

### Two shapes worth knowing about

Both come from an undocumented CLI contract, and each produced a defect the first version of
this change shipped.

**A create that reports success and cannot be seen afterwards.** The registrar treats the job
appearing in the listing as the proof it round-tripped, because `create`'s own output is
undocumented. The first version retried the *create* when that proof did not arrive, which
turns one unverifiable write into one automation per attempt, and N more on every restart —
AC2 inverted. It now creates at most once per start and retries only the lookup:
`should_create_at_most_once_when_the_listing_never_shows_the_job` pins that, and
`should_retry_the_create_when_the_create_itself_failed` pins the case where retrying *is*
right, because a create that failed wrote nothing.

**A listing whose key names are not the ones guessed at.** 003's lookup read `id`/`jobId`/
`job_id` and `name`/`jobName`/`title`, because none of them was documented. Its first version
let a parsed-but-unmatched envelope stand as a definite absence, so a deployment using any
other key name would register a duplicate on every start forever. The fix then was to consult
the plain listing as a second opinion. 011 replaced both with a strict read of the envelope its
probe pinned: a listing or row of any other shape permits no write.
`should_not_duplicate_the_briefing_when_the_listing_key_is_unrecognised` still pins the
outcome that matters, which is no second briefing.

### What the stub cannot tell you

The stub answers *given this CLI contract, does the entrypoint do the right thing*. It cannot
answer whether the contract is right. When 003 shipped, two parts of it were not doc-verified
upstream: `automations list --json`'s envelope, and whether a CLI call inside the container
holds `operator.admin`. The registrar was written to survive being wrong about the first —
hence `should_register_the_briefing_when_the_listing_is_object_wrapped` and
`..._when_list_json_is_unavailable`, which drove the tolerant paths — and to fail loudly on
the second. 011's probe has since pinned the envelope against the binary. The stub's default
now prints it, and the tolerant paths are gone: the cases that drove them now assert that a
listing the registrar cannot read leads to no write.

## The briefing's `gog` commands

The prompt this suite registers names three commands, and for as long as it had existed two of
them could not run. Against the pinned gog (v0.39.1):

```
$ gog calendar list --date today
unknown flag --date, did you mean one of "--days", "--page"?           # exit 2
$ gog gmail search 'newer_than:12h' --json
missing --account (or set GOG_ACCOUNT, set default via `gog auth manage`, or store exactly one token)   # exit 2
```

The first is a flag gog does not have. The second is the account: gog reads `GOG_ACCOUNT`, this
image's variable is `GOG_GOOGLE_ACCOUNT`, and only `hermes-check` passed it on. An agent told
"do not ask what to do" then took gog's own suggestion, and `gog auth manage` tried to open a
browser — `exec: "xdg-open": executable file not found in $PATH` — which is what the user
received in place of a briefing.

Every case here was green throughout, and that is the point of this section. The stub stores
whatever prompt it is handed and nothing in the suite runs `gog`, so a prompt naming a command
that does not exist registers perfectly. What the cases can hold, they now hold:

- **The commands, by name.** `--date` is refused, and the calendar step is pinned to the form
  `hermes-check` already runs against the same binary.
- **The account, by environment.** The stub's `gateway` records the `GOG_ACCOUNT` it was started
  with, in `gateway-gog-account`, and writes nothing when the variable is unset — so "exported
  empty" and "not exported" are different answers. That environment is the one every command
  the agent runs inherits. Six cases cover it: set, set alongside a service account key, unset,
  an operator's own `GOG_ACCOUNT`, the two disagreeing, and the two agreeing.
- **The instructions.** The briefing and `AGENTS.md` both say to report a failed `gog` command
  rather than repair it, and never to run `gog auth`. The briefing also says the output of its
  two bare commands is third-party text with no fence around it.

`install_gog_stub` in `harness.sh` puts a recording `gog` on `PATH` for the one case that takes
the service-account branch. No other case calls `gog`, so no other case needs it.

What still cannot be asserted here is that gog accepts the commands — only the binary can say.
The check that found this ran each command the registered prompt names against the real gog,
in the environment the gateway was exec'd with, with HTTPS pointed at a closed port so that
reaching the network meant the arguments and the account had both been accepted. Do the same
when the prompt's commands change, and when `openclaw_gog_version` is bumped.

## Sensitivity

When 003 landed, all 42 of its cases failed against the entrypoint before it:

```bash
ENTRYPOINT=/path/to/old/entrypoint.sh HARNESS_REGISTRAR_TIMEOUT=4 \
  .specs/003-cron-registration-via-cli/tests/registration-test
ENTRYPOINT=/path/to/old/entrypoint.sh HARNESS_REGISTRAR_TIMEOUT=4 \
  .specs/003-cron-registration-via-cli/tests/failure-test
```

That is 0 passed / 23 failed and 0 passed / 19 failed.

`HARNESS_REGISTRAR_TIMEOUT` bounds the wait for a terminal `cron:` line, in twentieths of a
second. It exists for exactly this run: an entrypoint with no registrar in it never emits one,
so every case would otherwise wait out the full default.

The clean sweep is not because every case tests registration directly. Six of them assert only
that the gateway started — `should_start_the_gateway_when_registration_succeeds`, the three
`should_start_the_gateway_when_…` failure cases, `should_register_nothing_when_the_briefing_target_is_partial`
and `should_not_create_a_job_when_the_automation_list_cannot_be_read`. Those are regression
guards: the old entrypoint also reached `exec`, and what they pin is that forking the registrar
before it did not take that away. They fail against the old entrypoint for a different reason —
`run_entrypoint` treats a registrar that never logs a terminal line as a failure, so a case
whose registrar never ran cannot report a pass on assertions it was in no position to make.

That is deliberate, and it is a defect this suite had. The wait's return status used to be
discarded, so a run where the registrar never logged read as green while every assertion after
it raced a subshell that was still working. Renaming `briefing_job_name` was enough to trigger
it: the harness's terminal-line pattern named the job, so the rename took `registration-test`
from 7 seconds to 5 minutes and it still reported 22 passed. The pattern no longer embeds the
name, and the timeout is now reported rather than swallowed.

## Mutations

```bash
HARNESS_REGISTRAR_TIMEOUT=200 .specs/003-cron-registration-via-cli/tests/mutation-check
```

Twenty-six mutations, one behaviour each, applied to a copy of `entrypoint.sh`. Every one must be
caught by at least one case; a mutation nothing catches is a hole in the suite. 003 shipped
twenty-one. 011 retired the three whose code it deleted, and re-anchored five on the code that
replaced theirs. Its own mutations, for the declaration and adoption, are in 011's
`mutation-check`. Eight more came with the `gog` cases above: the flag restored, each of the
three instructions dropped, and four ways of getting the account wrong. This one is not part of `run` because it re-runs the suites once per
mutation — `registration-test` first, and
`failure-test` only when nothing has caught the mutation yet, since that is much the slower of
the two.

Each mutation asserts its anchor matches exactly one line before applying itself, and reports a
bad anchor rather than a caught or uncaught mutation. 002 learned that the hard way — two of its
mutations anchored on a string that also occurred in a neighbouring block, so they mutated code
nothing there tested and read as uncaught.

The guard earned its place here on the first run. `drops the untrusted-content boundary from the
prompt` originally anchored on `Text between <untrusted-email> and </untrusted-email>`, which also
matches the heartbeat prompt at `entrypoint.sh:44` — 001's line, in 004's region. Without the
guard it would have mutated the heartbeat prompt, which nothing here tests, and reported an
uncaught mutation against a case that is in fact fine. It now anchors on `report that fact in the
briefing instead of doing it`, the clause that differs between the two prompts.
