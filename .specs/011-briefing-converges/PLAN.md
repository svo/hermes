# Plan: The morning briefing follows its configuration

> Adapted from the `plan` skill — see [`.specs/README.md`](../README.md) § Template adaptation.
> Spec: [`SPEC.md`](SPEC.md)

## The probe

Task 1 was run against `OpenClaw 2026.9.2 (3928bad)`, installed from npm into a scratch
directory. The host's node v22.23.1 satisfies its `engines`. It ran with an isolated `HOME`,
onboarded with the flags `entrypoint.sh` uses, and a loopback gateway on port 18911. Every
`automations` call needed only `--port`; no token was passed. stdout and stderr were captured to
separate files with exit codes, and a second reviewer re-read the raw files against every
verdict. The log is not in the repository.

| # | Claim | Result |
|---|---|---|
| B1 | `create --help` lists `--declaration-key` and `--disabled` | **held** |
| B2 | Declaring twice with the registrar's argv: the second is `created: false, updated: false`, same id | **falsified as worded** — see below. Same id: held (R2). No write: not on the first re-declaration |
| B3 | A changed schedule, timezone, prompt or delivery returns `updated: true` with the same id, and `get` shows it | **held**, all four. Removing the target gives `{mode: announce, channel: last}`, the same as a fresh registration |
| B4 | A disabled job stays disabled across unchanged and changed declarations; an explicit `--disabled` disables | **held**, including through B2's spurious write |
| B5 | `list --all --json` is `{ "jobs": [ … ] }`; `declarationKey` only on declared rows | **held**. Rows are full job objects. Top-level keys: `jobs`, `snapshotRevision`, `total`, `offset`, `limit`, `hasMore`, `nextOffset`, `deliveryPreviews` |
| B6 | An unkeyed `morning-briefing`, then a declaration, gives two jobs; `edit` cannot add a key | **held** — R5 and the reason adoption exists |
| B7 | A `heartbeat-task:` or `skill-collection-review:` key is rejected | **held**, exit 1 |
| B8 | With `--agent` omitted, the warning is on stderr and stdout is pure JSON | **held**. Merged with `2>&1`, it does not parse |
| B9 | `remove <id>` exits 0; an unknown or already-removed id exits non-zero | **held**. `{"ok": true, "removed": true}`; otherwise exit 1, `Automation not found: <id>` |
| B10 | Shapes | A keyless `create` prints a flat job object. A keyed one prints `{created, updated?, job, deliveryPreview}`, with `updated` absent when `created` is true |
| B11 | Concurrent declarations of one key | **one job**, in four trials including a four-way race |

### B2: the stop condition, and what it actually found

The task said to stop if B2, B3 or B4 failed, because those carry the strategy. B2 failed — but
not in the way the stop condition was written to catch. Every re-declaration converged onto the
same job, so there was no duplicate and no lost job. What failed is R4, "an unchanged declaration
writes nothing":

- With the registrar's argv (`"0 8 * * *"`, no `--exact` or `--stagger`), the first unchanged
  declaration after a create writes, and reports `updated: true`. So does the first one after
  **every gateway start**.
- Only a later declaration in the same gateway lifetime is a no-op.
- The stored job is byte-identical before and after; only `updated_at` moves.

The cause is in the shipped code. Re-applying an unchanged cron expression returns
`{…schedule, staggerMs: previous.staggerMs}`, which adds an explicit `staggerMs: undefined` to a
schedule stored without one. The convergence check then compares with `isDeepStrictEqual`, which
counts `{staggerMs: undefined}` and `{}` as different. A restart reloads the job from JSON and
drops the key again. It is an upstream defect.

**For this plan, the effect is that a once-per-start registrar would write on every start and log
`updated`, never `unchanged`.** SPEC's "no start wrote to it" could not be met, and the log line
meant to confirm a configuration change would fire whether or not anything changed.

**Decided: declare with `--exact`.** That was the verified mitigation. That stores `staggerMs: 0`
explicitly, and unchanged declarations are then no-ops, including the first after a restart. A
job first declared without it converges once (`updated: true`, `staggerMs: 0` added) and is
quiet from then on. For `0 8 * * *` it changes nothing about when the job runs: OpenClaw staggers
only top-of-hour recurring expressions by default. For an hourly `0 * * * *` it would remove that
default stagger of up to five minutes; the README says so. The edit-in-place fallback the stop
condition named was not taken. It would have avoided this defect at the cost of every reason SPEC
Open Question 3 rejected it, while declarations held everywhere B2 was written to test.

### Facts the plan absorbs either way

- **A failed `create` or `remove` still prints JSON on stdout:** `{"ok": false, "error": …}`. The
  exit code decides success, and the outcome is parsed only after a zero exit.
- **The gateway declares jobs of its own:** `heartbeat:main`,
  `memory-core:memory-dreaming-promotion` and `skill-collection-review:main`. None is named
  `morning-briefing`, so the partition ignores them. The strict parser requires `id` and `name`
  on every row, and all of them carry both.
- **A declaration does not validate the delivery channel** against configured channels.
  `deliveryPreview.detail` carries the warning instead. The registrar's both-or-neither check is
  unaffected.
- **The losing side of a concurrent declaration reports `updated: true`,** which is B2's
  settling write. The two-containers risk below holds as written.

## Implementation Strategy

**Replace the registrar's lookup and registration, and nothing else in 003's block.** The prompt,
the both-or-neither delivery check, the three budgets, `wait_for_gateway`, `briefing_one_line`
and the fork before `exec` stay as they are. What changes is the question the registrar asks.
003 asked "is a job with this name present?". 011 asks "which jobs by this name are mine, which
predate keys, and has the declaration landed?".

Each attempt is a short state machine. Every arrow is one bounded `openclaw` call:

```
read ──unparseable/failed──> retry (no writes)
  │
  ├─ not yet declared this start ──> declare ──failed──> retry the declare
  │                                     │
  │                                   succeeded ──> read again (no sleep)
  │
  └─ declared ──> is a job carrying the key listed?
                    ├─ no  ──> retry the read only
                    └─ yes ──> remove each unkeyed `morning-briefing` (non-fatal)
                               └─> one terminal line, return 0
```

**Read.** `automations list --all --json`, parsed **strictly**. The pinned CLI pages through
`cron.list` and prints `{ "jobs": [ … ] }` (`v2026.9.2`
`src/cli/cron-cli/register.cron-add.ts:69-71`, `list-jobs.ts:36-57`). A listing is accepted only
if it is an object with a `jobs` array whose every row has a string `id` and a string `name`.
Rows named `morning-briefing` are partitioned three ways:

- **ours** — `declarationKey` is `hermes:morning-briefing`;
- **unkeyed** — no `declarationKey`;
- **foreign** — any other key. Left alone.

Anything else counts as unparseable, and an unparseable listing permits no write. 003 tolerated
any envelope and fell back to the plain listing, because the envelope was undocumented and its
only question was presence, which the plain listing can answer. Both reasons are gone. The
envelope is now read from source and pinned by task 1, and the question needs `declarationKey`,
which only the JSON carries (R6). The plain-listing fallback is deleted. Keeping it would answer
"present" for an unkeyed job and declare beside it — a second briefing.

**Declare** on every start, not only the first, because convergence is the point and R4 makes an
unchanged declaration free — **provided the declaration carries `--exact`**. Without an explicit
stagger, the first unchanged declaration after every gateway start writes and reports `updated`
(§ The probe, B2), so the registrar always passes `--exact`. It is still **at most once per start**, which keeps 003's guard. A
declaration is idempotent by key, so retrying one should be harmless. But "should" rests on R2,
and the cost of R2 being wrong is the cost 003 already measured: one job per retry, then N per
restart. After a successful declare, only the read is retried.

`--disabled` is passed in exactly one case: this start's first read found **no** job carrying
the key and found unkeyed `morning-briefing` jobs, **every one** of them disabled. That is
adoption carrying an operator's "off" across, and "enabled if any of them was" is SPEC's rule
for more than one. When a job with the key exists, `--disabled` is never passed, so the scheduler
preserves whatever `enabled` the operator left (R3).

**Confirm, then remove.** The declare's own output is not what proves it landed. 003's rule
holds: success is the job appearing in the listing. Here that rule also gates the only
destructive step, because removal waits until a re-read shows a job carrying the key. That is
what makes SPEC Open Question 2's "never zero" a property of the code rather than of the happy
path. Each unkeyed job is then removed by id. A failed removal is logged and does not fail the
registration, because the declared job is in place and the next start's read will find the
leftover and try again.

**Report.** The terminal line is chosen from the declare's stdout, which at the pinned version
is `{ "created": …, "updated"?: …, "job": { … } }` (`server-methods/cron.ts:199-210`):

| `created` | `updated` | Terminal line |
|---|---|---|
| `true` | — | `cron: registered morning-briefing <id>` — 003's wording, kept |
| `false` | `true` | `cron: updated morning-briefing <id>` |
| `false` | `false` | `cron: morning-briefing unchanged (<id>)` |
| unparseable | | `cron: declared morning-briefing <id>; outcome unavailable` |

`<id>` comes from the confirming re-read, not from the declare's output, so all four lines can
name it.

**The declare's stdout is read apart from its stderr.** It runs on every start now, and the
pinned CLI warns on stderr whenever `--agent` is omitted (`register.cron-add.ts:392-402`). 003
captured `2>&1`, which was harmless while the output was only ever logged on failure. Merged, the
warning would make every outcome unparseable. stderr goes to a `mktemp` file owned by the
registrar subshell and removed when it exits. It is read only to build a failure reason, so a
successful start does not log the warning every time. Even then it is the fallback. A refused
declare prints `{"ok": false, "error": {"message": …}}` on stdout, and its stderr repeats the
reason after the warning, between `[openclaw]` banner lines (§ The probe, B7). So the reason is
`error.message` when stdout carries one, and stderr only when it does not. That is also what
keeps 003's `should_keep_a_multi_line_error_on_one_log_line` true unchanged once task 3 moves
the stub's failing create to the real shape (task 2's record).

**One behaviour change, one commit.** Declaring without adopting would add a keyed job beside
every existing unkeyed one, so no intermediate state is safe to deploy: the read, the declare,
the confirmation and the adoption land together. The other suites' stubs are made ready first,
in a commit that keeps them green against the *current* registrar. That ordering is what keeps
every commit in this plan green.

## Layer Changes

### Provisioning
None. `openclaw_version: 2026.9.2` already carries `--declaration-key` — subject to task 1.

### Runtime configuration (`roles/openclaw/files/entrypoint.sh`)

Owned region: inside 003's registrar, the `briefing_create_args` array, `lookup_briefing_job`
and `register_briefing`. Declared as a crossing in SPEC § Planned Crossings.

- `briefing_declaration_key='hermes:morning-briefing'`, defined beside `briefing_job_name`.
  `--exact` and `--declaration-key "$briefing_declaration_key"` are appended to
  `briefing_create_args`. The key begins with neither reserved prefix (R7). `--exact` is what
  makes an unchanged declaration a no-op across restarts (§ The probe, B2), and its comment says
  so. A later reader who removes it as noise would bring back a write and an `updated` line on
  every start.
- `lookup_briefing_job` → `read_briefing_jobs`. One `node -e`, fed the listing through the
  environment as today. It prints one line per matching row — `ours <id> <enabled>`,
  `unkeyed <id> <enabled>` — and exits 2 when the listing fails the strict shape. Foreign rows
  print nothing. The recursive walker and the plain-listing fallback are deleted.
- `register_briefing` — the state machine above. `created` becomes `declared`, with the same
  at-most-once meaning.
- `remove_unkeyed_briefings` — one `timeout`-bounded `openclaw automations remove <id>` per
  unkeyed row. It logs one non-terminal line per id either way and returns 0.
- The give-up line keeps its prefix, `cron: giving up after <n> attempts;`, and gains an honest
  suffix. If any read this start saw a job carrying the key, it says
  `briefing left as it was (<why>)`; otherwise it says 003's `briefing not scheduled (<why>)`.
  A failed declare against an existing job leaves a briefing running on its old configuration,
  and "not scheduled" would be a line that is a lie. *(Superseded at implementation: review
  found two more states where "not scheduled" is false. See task 3's record.)*
- **Do not** touch the prompt heredoc, the delivery checks, the budget validation,
  `wait_for_gateway`, `briefing_one_line`, or the fork line.

### Agent pipeline / Agent instructions / Image & CI
None.

### Documentation
- `README.md` § Morning Briefing:
  - the log-line table, with the new terminal lines and both non-terminal ones;
  - the paragraph "The job is looked up by name before it is created", which becomes the
    declaration and the one-time adoption;
  - a statement that the environment decides schedule, timezone, target and prompt on every
    start, that `automations edit` changes to them are replaced, and that a disabled briefing
    stays disabled;
  - that the briefing runs at exactly `HERMES_CRON_SCHEDULE`, with no stagger. This only matters
    for an hourly top-of-hour schedule, which would otherwise get OpenClaw's default random
    delay of up to five minutes.

  The two-containers paragraph improves and should say so. Two concurrent declarations of one
  key converge under the scheduler's lock instead of racing to create.
- `.specs/README.md`:
  - 011's ownership row;
  - the dependency graph, with 003 → 011 → 010;
  - the status line.

## Configuration Contract

No new variables. As SPEC § Configuration Contract: the four briefing inputs and the image's
prompt converge into the job on every start, and the job carries
`declarationKey: hermes:morning-briefing`.

The registrar's calls, in full:

| Call | When | Bounded by |
|---|---|---|
| `openclaw automations list --all --json` | Every attempt | `HERMES_CRON_CALL_TIMEOUT` |
| `openclaw automations create <schedule> <prompt> --name morning-briefing --tz <tz> --session isolated [--announce --channel <c> --to <t>] --exact --declaration-key hermes:morning-briefing [--disabled]` | Once per start, after a successful read | twice that, as today |
| `openclaw automations remove <id>` | Once per unkeyed row, after the declared job is listed | `HERMES_CRON_CALL_TIMEOUT` |

## Task List

1. [x] **probe** — **run; see § The probe. B2 failed as worded (R4). Its verified
       mitigation, `--exact`, was adopted. B1 and B3–B11 held.** Run against `openclaw@2026.9.2`, the
       version `defaults/main.yml` pins,
       installed into a scratch directory with a loopback gateway, as 009 ran its probe:
       - `automations create --help` lists `--declaration-key` and `--disabled`.
       - Declaring twice: the second returns `created: false, updated: false`, with the same id
         (R2, R4).
       - Declaring with a changed `--cron` / `--tz` / prompt / `--to` returns `updated: true`,
         with the same id (R3).
       - `automations disable <id>`, then declaring again: still disabled (R3).
       - `automations list --all --json` is `{ "jobs": [ … ] }`, with `declarationKey` on the
         declared row only (R6).
       - Creating `morning-briefing` without a key and then declaring one yields two jobs (R5,
         and the reason adoption exists).
       - A `heartbeat-task:` key is rejected (R7).
       - With `--agent` omitted, the warning is on stderr and stdout is pure JSON.
       - `automations remove <id>` exits 0, and exits non-zero for an unknown id.

       Record the outputs here, in § The probe, as 009 did. **If the second, third or fourth
       bullet fails, stop.** The strategy falls back to SPEC Open Question 3's edit-in-place,
       which was rejected on cost, not feasibility. The production half is SPEC's two
       verify-locally commands, and needs the deployment.
2. [x] tests: **teach every stub the declared CLI, and widen every harness's terminal-line
       pattern**, green against the *current* registrar so it lands alone. **Done — see the
       record below the list.**
       - `004`, `007`, `008`, `009` — `list` answers JSON with one `morning-briefing` carrying
         the key. The current registrar's walker finds it and logs `already registered`, as
         now. `create` prints `{"created":false,"updated":false,…}`.
       - `006` — the store-backed stub records the key and `enabled`. `list --json` emits the
         `{jobs}` envelope, and `create` prints the JSON outcome. `config-schema-check`'s
         `cron: registered morning-briefing` keeps holding, both now and after task 3.
       - `003` — the full model; see § Testing Strategy.
       - Every wait pattern becomes
         `^cron: (registered |updated |.* unchanged |declared |.* already registered |giving up )`.
         `already registered` is dropped in task 3.
       - `002` is unchanged: its stub never modelled `automations` and its harness never waits.

       **Record.** Three things were not in the list above:
       - 003's harness gained `stub_call_order` and `store_write_count`, which 011's copy
         inherits.
       - The full stub's ids now come from a counter, so a removed job's id is never issued
         again.
       - Its `renamed` shape is now an envelope whose rows use other key names. A strict reader
         therefore has to refuse rows as well as envelopes.

       Three things are kept until task 3 replaces what they protect:
       - **003's `OPENCLAW_STUB_CREATE_FAILS` still fails on plain stderr.** It prints no
         `--agent` warning, and no `{"ok":false,…}` on stdout. The current registrar merges
         create's two streams into its failure reason, and
         `should_keep_a_multi_line_error_on_one_log_line` pins that reason's exact text. Task 3
         moves the switch to `refuse`'s shape, and the case must then pass unchanged. That is
         why the reason comes from stdout's `error.message` (§ Implementation Strategy). The
         refusals the current registrar cannot reach — a reserved key, an ambiguous key, a
         failed or unknown `remove` — already use the real shape.
       - **`OPENCLAW_STUB_LIST_SHAPE=wrapped` stays**, for the two cases task 3 folds into the
         defaults, and goes with them.
       - **006's store is keyed by name.** It refuses a create that would need two jobs of one
         name, rather than modelling adoption. Nothing in 006 seeds the store, so nothing there
         needs adoption.
3. [x] runtime-config + tests: **the registrar rewrite**, with 003's inverted cases in the same
       commit, because they pin the behaviour being replaced:
       - the key, `--exact`, and the flag;
       - `read_briefing_jobs`, which deletes the walker and the plain-listing fallback;
       - declare at most once per start, with stdout and stderr apart;
       - confirm, then remove;
       - the four terminal lines and the honest give-up suffix;
       - `already registered` dropped from every wait pattern.

       **Record.** Additions the list did not name:
       - `briefing_failure_reason` builds every failure reason. It takes stdout's
         `error.message`, then stderr, then stdout, then the exit status (§ Implementation
         Strategy).
       - The stderr file comes from `mktemp` in the registrar subshell and is removed by its
         `EXIT` trap. If `mktemp` fails, the registrar logs one `giving up after 0 attempts`
         line rather than none.
       - A row whose `declarationKey` is `null` counts as unkeyed, the same as an absent one.
       - A briefing row whose id contains whitespace makes the listing unreadable, because
         the shell reads those lines back.

       **Review.** An independent review of the rewrite found four defects, each reproduced
       against the real entrypoint, and all four are fixed:
       - **A timed-out create was logged with the `--agent` warning as its reason.** A hung
         create prints the warning and nothing else, so stderr was the only text there was.
         A timeout is now named before stderr is read.
       - **"Briefing not scheduled" was false in two states.** One is an adoption whose
         declaration failed: the older job still runs. The other is a declaration that landed
         and was never confirmed: a declared job may exist. The suffix is now chosen from
         what the start knows:
         - `declared but not confirmed` once create has said yes;
         - otherwise `left as it was` when any briefing was listed, keyed or not;
         - otherwise `not scheduled`.

         The third line is new, and SPEC's Operability table carries it.
       - **Jobs were matched by name before key.** A job the operator had renamed was missed.
         Beside a disabled leftover, that start passed `--disabled` and switched the
         operator's briefing off, which breaks R3. Ours is now any job carrying the key,
         whatever its name.
       - **The listing reached node through an environment variable.** Linux caps one at
         128 KiB, which is about a hundred automations, after which no start could read the
         listing. It now goes in on stdin. A listing that says `hasMore` is refused too. The
         pinned CLI reads every page before printing, so a partial page would mean the CLI
         changed.

       The review's coverage gaps are closed as well:
       - every terminal path, timeouts included, is now counted;
       - the several-unkeyed cases now pin both directions;
       - a hand edit now includes delivery;
       - a failing declaration over an unkeyed job now has a case.

       011's stub gained hang modes for `list`, `create` and `remove`, and a `partial` listing
       shape, to drive these.

       Changes to 003's suite:
       - The stub's `CREATE_FAILS` now refuses in the real shape.
       - `wrapped` went, with the two cases that drove it.
       - The garbage, renamed and `--json`-refused cases now seed an unkeyed briefing, so that
         "no duplicate" means something under a registrar that writes nothing on an
         unreadable listing.
       - 003's tests README was brought in step.
4. [x] tests: **011's suite** — `harness.sh` and `stub-openclaw` copied from 003's as task 2
       leaves them, as 009 copied 008's, plus `convergence-test`, `adoption-test`, `run` and
       `README.md`. **Record:** 42 cases, 23 and 19, eight of them added after review (task
       3's record). Against the pre-011 entrypoint, 40 fail. The suite's README explains the
       two that pass. Each guards a way only the new registrar could break.
5. [x] tests: **`mutation-check`** for 011, and 003's anchors brought in step:
       - **Retired:** the three mutations whose code is gone — the plain-listing fallback, the
         bare-array walk, the unrecognised envelope.
       - **Re-anchored:** `lists only enabled automations` (two occurrences become one), and
         `creates again after a create that already succeeded` (`created` → `declared`).

       **Record.** 003's mutations needed three more re-anchors than listed above, because
       their code moved: `creates without looking first`, `swallows the underlying error`,
       and `lets a multi-line error break the one-line log contract` (three occurrences
       became two). That leaves eighteen.

       011's check has the eleven mutations above, plus three for behaviour the list did not
       name:
       - `drops the id from the terminal line`;
       - `calls every failed declaration unscheduled`;
       - `takes the reason from stderr when the JSON has one`.

       **Results:** 011's eighteen and 003's eighteen are all caught, against the final code.
       003's original twenty-one were also all caught against task 2's state, which is what kept
       task 2 green on its own. Every other suite passes against the final registrar with the
       same counts as before task 2 (004, 006, 007, 008, 009, and 006's config-schema-check), and
       so does `bin/test`.
6. [x] docs: `README.md` § Morning Briefing.
7. [x] docs: `.specs/README.md` — ownership row and status. The dependency graph was already
       drawn when 011 was planned.

## Testing Strategy

No test framework exists. As every spec here does, the real `entrypoint.sh` runs against a stub
`openclaw` with a private `HOME`, and the automation store the stub keeps is what cases read.
**Every convergence case is a restart over a seeded store.** A single start can never show
convergence, because the job has to exist with one configuration before a start with another
means anything. `run_entrypoint --store` already shares a store across starts. A seeded store
also models "an older image registered this", which is how a prompt change is tested without
editing the entrypoint.

### The stub (003's, then copied)

It keeps everything 003 deliberately made strict, including rejecting unknown flags, and learns
the declared CLI as task 1 recorded it:

- **The store** — rows gain `declarationKey`. `list --json`'s default shape becomes the
  `{ "jobs": [ … ] }` envelope. `OPENCLAW_STUB_LIST_SHAPE` gains `bare`, and keeps `garbage` and
  `renamed`. All three must now be refused, not tolerated.
- **Upsert** — `create --declaration-key` converges schedule, tz, prompt, delivery and stagger
  onto a row with that key. It models B2's defect too: a row stored without an explicit stagger
  reports `updated: true`, and counts a write, on its first unchanged declaration in each run.
  Each `run_entrypoint` is a gateway start, so a registrar that dropped `--exact` writes on every
  start, and `should_write_nothing_when_five_restarts_change_nothing` notices. It changes `enabled` only for an explicit `--disabled`, prints
  `{created, updated, job}`, and does not touch the store when nothing differs. That last point
  is how "no start wrote to it" is asserted: the stub bumps a write counter only on a real
  write.
- **Refusals** — more than one row with the key (R8), and a reserved prefix (R7).
- **The `--agent` warning** — on stderr, on every `create`, as the real one does. Without it,
  the stdout/stderr separation has no case.
- **`remove <id>`** — deletes by id, or exits 1 for an unknown one.
- **New switches:**
  - `OPENCLAW_STUB_REMOVE_FAILS=yes`;
  - `OPENCLAW_STUB_CREATE_OUTPUT=garbage`, a successful create whose stdout is not JSON;
  - a call-order log, so "declare before remove" is asserted on the sequence, not inferred.

### 003's cases that invert

| Case | Becomes |
|---|---|
| `should_not_register_a_second_time_when_the_briefing_already_exists` | `should_leave_the_briefing_unchanged_when_the_container_restarts` — one `create` per start, one job, `unchanged` |
| `should_find_the_briefing_when_it_is_disabled` | Seeded *with the key*: stays disabled, no duplicate, `--all` passed. The unkeyed variant moves to 011's `adoption-test` |
| `…_when_the_listing_is_object_wrapped` (two cases) | Folded into the defaults — the envelope is now the only accepted shape. Replaced by `should_write_nothing_when_the_listing_is_a_bare_array` |
| `should_register_the_briefing_when_list_json_is_unavailable` | `should_write_nothing_when_list_json_is_unavailable` — the inversion that matters most: 003 created here; 011 must not |
| `…_garbage`, `…_renamed` | Keep their names. They also assert `create` calls `0`, and lose their `already registered` assertions |
| failure-test: the two `create succeeds without storing` cases | Same behaviour, new message: `declaration reported success but no automation carries hermes:morning-briefing` |

Everything else in 003's suite is untouched. Readiness, timeouts, budgets, delivery validation,
prompt content, fencing and the one-line contract are still 003's, and are still true.

### 011's cases, by acceptance criterion

**`convergence-test`** — SPEC § Declared registration:

- `should_declare_the_briefing_under_the_hermes_key_when_the_store_is_empty`
- `should_write_nothing_when_five_restarts_change_nothing` — same id, write counter at one, five
  `unchanged` lines
- `should_carry_the_new_schedule_on_the_same_job_when_the_schedule_changes`
- `…_timezone_…`, `…_target_…`, `…_prompt_…` — the prompt case seeds a keyed job holding an
  older prompt
- `should_restore_a_fresh_registrations_delivery_when_the_target_is_removed`
- `should_keep_a_disabled_briefing_disabled_when_the_container_restarts`
- `…_when_the_schedule_changes` — disabled survives a real convergence, not only a no-op
- `should_replace_a_hand_edit_when_the_container_restarts`
- `should_declare_under_a_key_outside_the_reserved_namespaces`

**`adoption-test`** — SPEC § Adopting:

- `should_replace_an_unkeyed_briefing_with_a_declared_one`
- `should_keep_the_briefing_disabled_when_the_unkeyed_one_was_disabled`
- `should_replace_every_unkeyed_briefing_with_one_when_there_are_several`
- `should_enable_the_declared_briefing_when_any_unkeyed_one_was_enabled`
- `should_declare_before_removing_when_adopting` — on the call log
- `should_keep_the_declared_briefing_when_the_unkeyed_one_cannot_be_removed`
- `should_remove_the_leftover_on_the_next_start_when_removal_failed`
- `should_not_remove_the_unkeyed_briefing_when_the_declared_one_is_not_listed` — `CREATE_SILENT`.
  This is the "never zero" case.
- `should_write_nothing_when_the_listing_cannot_be_read` — and when it is `garbage`, `bare`,
  `renamed`, or `--json` is refused
- `should_leave_a_briefing_with_another_key_alone`

**Failure and logging** (in `convergence-test`):

- one case per terminal line
- `should_report_an_unavailable_outcome_when_create_output_does_not_parse`
- `should_read_the_outcome_when_create_warns_on_stderr`
- `should_say_the_briefing_was_left_as_it_was_when_giving_up_with_one_in_place`
- `should_emit_exactly_one_terminal_line_on_every_path` — counted across a restart sequence that
  visits every outcome

### Sensitivity

The red baseline is the pre-011 entrypoint, run with 011's suite and task 2's stubs. Every
convergence and adoption case should fail against it. A case that passes there must be one that
asserts nothing changes; say which, as 009's README did, rather than claim a clean sweep.
`mutation-check` then mutates one behaviour at a time:

- declares without the key
- declares without `--exact`
- removes before declaring
- removes without confirming
- removes a foreign-keyed job
- drops `--disabled` on adoption
- passes `--disabled` whenever any unkeyed job is disabled
- tolerates a bare-array listing
- merges stderr into the outcome
- reports every outcome as `registered`
- declares again after a declare that succeeded

Each must be caught.

Naming: `should_<behaviour>_when_<condition>`. The suite is not wired into `bin/test`, following
002–004 and 007–009. The gate still lints it, because discovery is by shebang.

## Observability Plan

| Line | Stream | Kind |
|---|---|---|
| `cron: waiting for gateway (up to <n> attempts)` | stdout | unchanged |
| `cron: registered morning-briefing <id>` | stdout | terminal — created |
| `cron: updated morning-briefing <id>` | stdout | terminal — converged |
| `cron: morning-briefing unchanged (<id>)` | stdout | terminal — nothing written |
| `cron: declared morning-briefing <id>; outcome unavailable` | stdout | terminal — landed, `create`'s output unreadable |
| `cron: replaced unkeyed morning-briefing <id>` | stdout | non-terminal, one per adopted job |
| `cron: could not remove unkeyed morning-briefing <id>: <error>; the next start will retry` | stderr | non-terminal |
| `cron: registration attempt <n>/<max> failed: <reason>` | stderr | unchanged |
| `cron: giving up after <n> attempts; briefing not scheduled (<why>)` | stderr | terminal — no briefing was listed, and nothing was declared |
| `cron: giving up after <n> attempts; briefing left as it was (<why>)` | stderr | terminal — a briefing was listed, keyed or not, and the declaration failed |
| `cron: giving up after <n> attempts; briefing declared but not confirmed (<why>)` | stderr | terminal — `create` succeeded, and no listing showed the key. Added at implementation; see task 3's record |

Retired: `cron: morning-briefing already registered (<id>)`. Every line passes through
`briefing_one_line`, so `docker logs hermes | grep '^cron:'` still shows whole messages.

## Risks and Mitigations

- **Risk:** the source reading behind R2–R6 is wrong, or the binary behaves differently from the
  scheduler code it ships. → **Task 1, before anything is written.** The four claims the strategy
  stands on each have a probe bullet, and the plan names its fallback if they fail.
- **Risk:** a later `openclaw_version` bump renames or drops `--declaration-key`. → The create
  then fails on an unknown option. The registrar logs it every start and gives up with
  "briefing left as it was", and no removal runs, because removal waits on a confirmed
  declaration. That is loud and non-destructive. 007's bump procedure gains a line: re-run task
  1's probe.
- **Risk:** upstream fixes the stagger defect, or changes what `--exact` means. → The fix is
  harmless: `--exact` stays correct. A change of meaning is caught by the same re-run of task 1
  on a version bump, whose B2 must still show `updated: false` on the first declaration after a
  restart.
- **Risk:** strict parsing turns an upstream envelope change into no convergence at all. → The
  same outcome as the previous risk, deliberately. Tolerance is what made 003's walker guess at
  key names, and a wrong guess here would declare beside an unkeyed job.
- **Risk:** adoption removes a job the operator made. → Only jobs named exactly
  `morning-briefing` **with no declaration key** are removed. The README has said since 003 that
  there is exactly one job by that name, and that it is the registrar's. A job carrying any other
  key is left alone, and has a case and a mutation.
- **Risk:** a moment with two briefings during adoption. → Accepted in SPEC Open Question 2. It
  needs the scheduled minute to fall between a declare and a remove a few hundred milliseconds
  apart. If the removal fails, the window lasts until the next start, and the log names the id.
- **Risk:** adoption discards the unkeyed job's run history and any hand edits on it. → Run
  history is kept seven days upstream anyway. Hand edits are replaced on every start under SPEC
  Open Question 1, so adoption loses nothing that would have survived.
- **Risk:** the `--agent` warning, now printed every start, breaks the outcome parse or floods
  the log. → stdout and stderr are captured apart. stderr is logged only inside a failure
  reason, and a case runs with the stub printing the warning.
- **Risk:** five other suites break, or slow to their timeouts, because their stubs answer the
  old calls. → **Not hypothetical: this is what the current stubs do.** 004's harness runs the
  default budgets, so a plain-text listing would cost each of its cases about ten seconds of
  waiting for a terminal line that never comes. Task 2 lands first, is green against the
  current registrar, and is what keeps task 3's commit green across every suite.
- **Risk:** `--disabled` is passed on an ordinary restart and switches the briefing off. → It
  is computed only when no job carrying the key exists. The mutation that passes it whenever an
  unkeyed job is disabled has a case: a keyed enabled job beside a disabled unkeyed one must
  stay enabled.
- **Risk:** two containers sharing a volume. → Better than 003. Two declarations of one key
  converge under the scheduler's lock rather than both creating. Two adoptions racing to remove
  the same unkeyed id leave one removal failing on an unknown id, which is logged and harmless.
- **Risk:** 010 ships before 011 reaches production. → 010 depends on 011 in `.specs/README.md`.
  010's briefing step would merely fail to arrive on the existing deployment, which is the
  status quo, not a regression.
