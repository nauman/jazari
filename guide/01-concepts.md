# 01 · Concepts

## The word that changed

If you already have something called a "runbook", it almost certainly means
*the whole thing* — a body of text plus a checklist, attached to a record.

**In jazari, `runbook` means only one part of that:** a single subject's
override of a shared procedure. The umbrella term is an **operating
procedure**, and it has four layers.

This is the single most common way to misread the API, so it is worth
correcting before you write any code against it.

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

Each answers a question the layer above it cannot.

### Recipe — the canon

How the ritual is done, as **data**. A row, not a constant: an operator edits it
at runtime, and fixing a procedure is a write rather than a deploy.

The gem ships **no recipe content at all** — not one checklist item. Yours are
yours. That is also what lets a fresh install arrive with working procedures
instead of an empty text box.

Editing a recipe changes its digest, which invalidates outstanding revisions
rather than letting them silently write onto changed ground.

### Runbook — one subject's override

Most subjects never need one. A runbook exists only when *this particular*
record genuinely differs from the canon.

It is materialised on the first edit. **Reading a default writes nothing** — no
row, no anchor, no audit noise. That matters more than it sounds: it means you
can resolve a procedure for ten thousand records without creating ten thousand
rows.

Reset destroys the override and reveals the *current* canon, so a later
correction reaches every subject that never overrode it.

### Queue — a name you can always call

The layer most systems lack, and the reason agents improvise.

Some procedures belong to no record. Verifying a backup is not one app's
business. Triaging an alert is not a property of a server row. Provisioning
happens before the machine exists.

Attach-to-a-record has no answer, so those procedures end up in a session log, a
learnings file, or an agent's private memory — findable only by someone who
already knows where to look.

A queue is a **stable name**:

```ruby
Jazari.resolve(target: Jazari::QueueTarget.new(
  queue: "backup-verify", public_reference: { kind: "queue" },
  recipe_id: "backup.verify.v1"
))
```

The name is the contract. Whatever record carries that truth today can move
without breaking the call.

Queues are **read-only** — a ritual has exactly one editable home, its recipe.

### Run — one execution

Without this, a checklist is a mutable singleton: you `reset` it to run again,
and in doing so destroy the only evidence it ever ran.

A run carries its own actor, ticks, a start and an end, and somewhere to attach
what you actually saw. Each tick and evidence entry records its actor too, so the
history stops being destroyed by the act of starting over.

A run also **snapshots its checklist when it opens**, so editing a recipe
mid-run does not break runs in flight.

## Three cross-cutting rules

**Revision guards.** Every mutation carries the revision from the read before
it. Mismatch raises `revision_conflict` instead of overwriting. This matters
most when several automated writers share one procedure.

**Idempotency belongs to the ritual, not the system.** Verifying a backup should
happen once a day; triaging an incident may happen five times. Each recipe
declares its own `run_policy`.

**You authorize; jazari never sees an actor object.** The domain accepts no raw
IDs or arbitrary records. You authorize first, then hand it exactly one immutable
target and an opaque `actor_ref` for audit history. Unknown, unauthorized, and
deleted targets all collapse to the same `target_not_found`, so guessing cannot
reveal what exists.

## What it is not

Not an execution framework. Jazari holds the *state* of a procedure. It does not
SSH anywhere, shell out, or run your commands.

That boundary is deliberate rather than a gap. Execution is already served by
whatever you have — CI, a rake task, a deploy tool — and it differs per shop.
What none of those keep is a durable, addressable record of which procedure ran,
who ran it, and what came back.

The name `runbook` was taken on RubyGems by a DSL for *executing* procedures;
that project last released in 2021 and last committed in 2022, so treat it as
historical context for the naming rather than something to build on.

## Where recipes live

In a table. That is what makes fixing a procedure a **write, not a deploy** — an
operator corrects a step at 3am without waiting for CI.

That does not mean the canon cannot be version-controlled. `Jazari::RecipeFiles`
reads YAML or JSON:

```ruby
Jazari::RecipeRegistry.seed!(Jazari::RecipeFiles.load("config/recipes"))
```

Call it from a **data migration**, not `db/seeds.rb` — boot usually runs
`db:prepare`, which seeds only on first create, so an existing database never
sees it.

**Files seed; they do not sync.** `seed!` is create-if-missing, so re-running it
never overwrites a row an operator has edited. This is the same rule the runbook
layer follows: a customisation diverges rather than rebasing, because silently
overwriting a deliberate edit with a change nobody saw is the worst outcome
available. Applying files on every deploy would do exactly that.

The cost of that choice is drift — a file and a row can disagree and nothing says
so. So ask:

```ruby
Jazari::RecipeFiles.drift(Jazari::RecipeFiles.load("config/recipes"))
# => [{ id: "deploy.v1", state: :differs, fields: [:topic] }]
```

It reports; it never resolves. What a difference *means* is yours to decide: on
one fleet the file is reviewed truth and a divergent row is an incident; on
another the row is an operator's fix and the file is stale.

And to close the loop — export what they actually changed, then diff it in a
pull request:

```ruby
Jazari::RecipeFiles.dump("config/recipes")
```

Without that export, runtime editing quietly becomes the thing you avoid rather
than the thing the design is built around.
