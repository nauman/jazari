# 04 · Runs and evidence

A checklist attached to a record tells you its *current* state. It cannot tell
you whether the procedure ran last night, who ran it, or what they saw — and
`reset`, the only way to run it again, destroys the answer.

A **run** is one execution.

```ruby
result = Jazari.open_run(target: target, actor_ref: "agent:nightly")
run = result[:run]

Jazari.tick(run: run, expected_revision: run.lock_version,
            item_id: "restore", done: true, actor_ref: "agent:nightly")

Jazari.attach_evidence(run: run.reload, expected_revision: run.lock_version,
                       item_id: "counts", kind: "count", value: "4211 rows",
                       actor_ref: "agent:nightly")

Jazari.close_run(run: run.reload, expected_revision: run.lock_version,
                 outcome: "completed")

Jazari.last_run(target: target).outcome   # => "completed"
```

`resolve` also carries `last_run`, so **one read** answers "is this ritual
actually happening?"

## Idempotency belongs to the recipe

There is no global rule, because no global rule is right.

| `run_policy` | Behaviour | Fits |
|---|---|---|
| `unrestricted` (default) | every call opens a run | incident triage |
| `once_per_calendar_day` | one run per recipe + subject + UTC day | backup verification |

Under the daily policy, a second call **returns the existing run** instead of
erroring, so a retrying cron converges:

```ruby
Jazari.open_run(target: target, actor_ref: "cron")
# => { run: #<Run id: 4412>, created: false, idempotent_reuse: true }
```

Read `created` if you care about the difference between "I opened tonight's run"
and "tonight's run already happened". Ignore it and everything still works — you
get a valid run either way.

If that day's run is already **closed**, you get it back closed. Ticking it
raises `run_closed`. A second run is never created silently.

### Why UTC, and why an index

The day boundary is **UTC**, via `timestamptz`. Server-local time would let one
nightly ritual land on two different days depending on which region's machine
called it.

Enforcement is a partial unique index, not application logic — a
find-then-insert races. The index `COALESCE`s the nullable polymorphic subject,
because a queue run has no subject and `NULL != NULL` means a plain unique index
would not constrain queue runs **at all**.

## Runs are bound to the canon they opened against

A run snapshots its checklist when it opens. Edit the recipe mid-run and the
in-flight run still ticks its own steps — and refuses steps that did not exist
when it started.

Without this, improving a procedure silently breaks every run in progress.

## Evidence

```ruby
Jazari.attach_evidence(run:, expected_revision:, item_id:,
                       kind: "count", value: "4211 rows", actor_ref: "agent:nightly")
```

Kinds are bounded — `output`, `url`, `sha`, `count`, `note` — deliberately.
Unbounded evidence turns into a log sink, and this is not a log. It is the
answer to "you say you verified it; show me."

If a procedure of yours currently says *"keep a timestamped record of command
results and object ids"*, that sentence is asking for this table.

### Actor defaults and inheritance

Actor identity is opaque and belongs to the execution, not the recipe. Pass a
different `actor_ref` when a different human, agent, or job acts. A configured
zero-argument `c.actor_ref` may supply a trusted system default when opening a
run. Explicit references win, while omitted ticks and evidence inherit the run's
actor. This keeps retries convenient without making the audit trail anonymous.

## Runs outlive their subjects

`Jazari.forget_subject` removes the override and **keeps the runs**. Their
subject columns keep pointing at a record that no longer exists, which is sound
precisely because no foreign key was ever claimed. Deleting a server does not
un-run last month's verification.
