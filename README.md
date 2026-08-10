# Jazari

**Operating procedures you can call, instead of documents you hope someone reads.**

Recipes as data, per-subject runbooks, stable names for rituals that outlive any
record, and per-run evidence — so *"did last night's run actually complete?"*
is a query rather than a guess.

Requires Ruby 3.2+, Rails 7.1+, and PostgreSQL.

---

## The problem

You have a procedure. Verify a backup by restoring it. Provision a server.
Triage an alert before waking anyone.

It is written down. It lives in a document, or a wiki, or a comment. And so:

- Nothing can **check it off**, so nobody knows how far a run got.
- Nothing knows whether it is **current**, so it rots silently.
- Nothing records **who ran it, when, or what they saw**.
- An agent cannot **call** it, because it has no name — only a location.

The usual fix is a checklist attached to a record. That helps, and then it
runs out: some procedures belong to no record at all, and a checklist you
`reset` to run again has just destroyed the evidence it ever ran.

## Four layers

```
RECIPE     the canon — how this ritual is done. Data, not code.
  ↓        operator-editable at runtime, digest-versioned
RUNBOOK    one subject's override — how THIS record differs
  ↓        materialised on first edit; reading a default writes nothing
QUEUE      a stable name for a ritual that outlives any record
  ↓        read-only: a ritual has exactly one editable home
RUN        one execution — who, when, which ticks, what evidence
```

Most systems stop at the second. The third makes a procedure **callable**; the
fourth makes it **auditable**.

## Install

```ruby
gem "jazari"
```

```bash
bin/rails generate jazari:install
bin/rails db:migrate
```

The generator copies one migration. **Jazari never auto-appends migrations** to
your schema — a shared operations table appearing in someone's next
`db:migrate` without them asking is how a gem loses trust in a production fleet.

## Thirty seconds

```ruby
# 1. Seed a recipe. The gem ships NO content — these are your procedures.
Jazari::RecipeRegistry.seed!([
  { id: "backup.verify.v1",
    topic: "Prove a backup by restoring it",
    description: "## Purpose\n\nA green schedule is not a verified backup.",
    run_policy: "once_per_calendar_day",
    checklist: [
      { id: "dump",    text: "Dump to scratch" },
      { id: "restore", text: "Restore into a throwaway database" },
      { id: "counts",  text: "Compare table and row counts" }
    ] }
])

# 2. Address the ritual by NAME. No record required.
target = Jazari::QueueTarget.new(
  queue: "backup-verify", public_reference: { kind: "queue" },
  recipe_id: "backup.verify.v1"
)

Jazari.resolve(target: target).progress   # => { done: 0, total: 3, percent: 0 }

# 3. Open a run, work it, attach what you saw.
result = Jazari.open_run(target: target, actor_ref: "agent:nightly")
run = result[:run]

Jazari.tick(run: run, expected_revision: run.lock_version,
            item_id: "restore", done: true, actor_ref: "agent:nightly")

Jazari.attach_evidence(run: run.reload, expected_revision: run.lock_version,
                       item_id: "counts", kind: "count", value: "4211 rows")

Jazari.close_run(run: run.reload, expected_revision: run.lock_version,
                 outcome: "completed")

# 4. The question that started all this:
Jazari.last_run(target: target).outcome   # => "completed"
```

## Idempotency belongs to the ritual

Verifying a backup should happen **once a day**. Triaging an incident may happen
five times. So there is no global rule — each recipe declares its own:

| `run_policy` | Behaviour |
|---|---|
| `unrestricted` (default) | every `open_run` starts a run |
| `once_per_calendar_day` | one run per recipe + subject + **UTC** day |

Under the daily policy a second call **returns the existing run** rather than
erroring, so a retrying cron converges:

```ruby
Jazari.open_run(target: target, actor_ref: "cron")
# => { run: #<Run id: 4412>, created: false, idempotent_reuse: true }
```

Enforced by a partial unique index, not by application logic — a
find-then-insert races. Two details that are easy to get wrong and are handled
here: the index `COALESCE`s the nullable polymorphic subject (otherwise queue
runs are unconstrained entirely, because `NULL != NULL`), and the day is **UTC**
via `timestamptz`, so one nightly ritual cannot land on two different days
depending on which region's machine called it.

## Revision guards

Every mutation carries the revision from the read before it:

```ruby
resolved = Jazari.resolve(target: target)
Jazari.check_item(target: target, expected_revision: resolved.revision,
                  item_id: "dump", done: true)
```

A customised runbook uses its `lock_version`; a default uses
`default:<recipe-digest>`. Editing a recipe changes its digest, so anyone
holding a stale default gets `revision_conflict` instead of silently writing
onto ground that moved. This matters most when several automated writers share
one procedure — last-writer-wins is the same defect class as two people
force-pushing a branch.

## Recipes are data, not code

The gem ships **no recipe content** — not one checklist item, only the
mechanism and an empty fallback. Your procedures are rows: seeded once, then
operator-owned. Reseeding never overwrites an edit.

That means fixing a ritual is a **write, not a deploy** — and a fresh install
can ship with working procedures instead of an empty text box.

## Runs are bound to the canon they opened against

A run snapshots its checklist when it opens. Edit the recipe mid-run and the
in-flight run still ticks its own steps, and refuses steps that did not exist
when it started. Without this, an operator improving a procedure silently breaks
every run in progress.

## MCP

`Jazari::Mcp::Handler` maps action names onto the domain and knows nothing about
transport, auth, or product naming:

```ruby
Jazari::Mcp::Handler.new.call(action: "get", target: target)
# => { ok: true, state: "default", topic: "...", progress: {...}, last_run: {...} }
```

**Tool identity stays yours.** Your app exposes its own flat `action`-enum tool
with its own subject vocabulary and permissions; this handler is the shared
implementation underneath. Domain failures cross the wire as codes from a closed
set — `target_not_found`, `invalid_runbook`, `revision_conflict`,
`item_not_found`, `read_only_target`, `run_closed` — never as messages that
could disclose a record or whether a target exists.

`Handler.actions_for("read")` returns the read-only subset, so a read-scoped
connection never advertises mutations.

## You authorize; Jazari never sees an actor

The domain accepts no raw IDs, no arbitrary records, and no actor. Your app
authorizes first, then constructs exactly one immutable target:

```ruby
Jazari::RecordTarget.new(runbookable: site, public_reference: { kind: "site" },
                         recipe_id: "site.maintenance.v1")
Jazari::QueueTarget.new(queue: "backup-verify", ...)   # read-only
Jazari::AnchorTarget.new(scope_type: "Tree", scope_id: 7, key: "node-x", ...)
```

`AnchorTarget` covers subjects that are not ActiveRecord rows — a JSON-tree
node, a file path, a DNS zone. Register the scope at boot; unregistered scopes
fail closed.

## Deleting a subject

Jazari cannot hook your models — a subject may live in a different logical
database, so no cross-database foreign key is claimed and no cascade exists.
Call in from your own `after_commit`:

```ruby
class Site < ApplicationRecord
  after_commit :forget_jazari, on: :destroy
  def forget_jazari = Jazari.forget_subject(self)
end
```

That removes the subject's runbook. **Runs are deliberately preserved** — a run
records something that actually happened, and deleting the subject does not
un-happen it.

## PostgreSQL only

The guarantees lean on Postgres: `jsonb`, `timestamptz`, four CHECK constraints,
and a partial unique index over a `COALESCE`d polymorphic subject. Supporting a
second adapter would make those conditional, which weakens the design. Other
adapters are additive — open an issue if you need one.

The test suite runs **the migration the gem ships**, so the schema cannot drift
out of coverage.

## What this is not

Not an execution framework. Jazari holds the *state* of a procedure — the canon,
the overrides, the runs, the evidence. It does not SSH anywhere or run your
commands.

For the execution half, see [braintree/runbook](https://github.com/braintree/runbook):
a Ruby DSL for running operational procedures, with resumable state and a dry-run
mode. It has no data model; Jazari has no executor. They compose.

## Why "Jazari"

Ismail **al-Jazari** (1136–1206), engineer at the Artuqid court in Diyarbakır,
built programmable automata — a hand-washing machine that offered you a towel,
a clock driven by a water wheel, pumps with the earliest known crankshafts.

That is not why the gem carries his name.

He also wrote *The Book of Knowledge of Ingenious Mechanical Devices*, finished
the year he died: fifty machines, each with numbered construction steps and
drawings detailed enough that a stranger who had never met him could rebuild the
device. He wrote down the *procedure*, not just the result — including, in his
own words, the steps he had gotten wrong first.

Eight hundred years later people have built working machines from those pages.

That is the whole idea here. A procedure is not lore in someone's head or prose
in a document nobody opens. It is a written, versioned, checkable artefact that
somebody else can execute and prove they executed.

`runbook` was taken on RubyGems — by the execution framework above, fittingly.

## License

MIT.
