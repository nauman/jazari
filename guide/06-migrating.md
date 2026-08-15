# 06 · Migrating an existing checklist

You already have a runbook table with live data. This is the shape of that
migration, written from doing it — including the parts that went wrong.

## The rule that governs everything

**Never widen the schema and tighten it in the same deploy.**

The first attempt at this added the new columns, backfilled existing rows, and
set `NOT NULL` — all in one migration. It reads as additive and is not: the
currently deployed code does not populate those columns, so every row it wrote
afterwards violated the constraint. Thirteen tests caught it; production would
have caught it less kindly.

Three phases:

| Phase | Deploy |
|---|---|
| 1 | add **nullable** columns, backfill what exists |
| 2 | ship the code that populates them |
| 3 | tighten to `NOT NULL` |

A unique index added in phase 1 must be **partial** (`WHERE col IS NOT NULL`),
or rows still written by the old path all collide on `(NULL, NULL)`.

## Do not reset `done`

Check before writing the migration: **someone is probably mid-procedure.** In
one real fleet, two subjects were in flight — 3 of 12 steps done on one, 13 of
14 on another. A migration that resets `done` erases that operator's work with
no trace and no complaint.

Carry `done` through. If you cannot, stop and say so before running it.

## Item ids — measure before you build a map

**Check whether your ids need translating at all before designing anything.**
Jazari item ids match `[A-Za-z0-9_-]{1,64}`, and the string form of an integer
satisfies that. In one real migration every id carried across verbatim, so the
ids quoted in deploy documentation kept resolving and no map was needed.

Do not reason from "the ids interleave across subjects, so no offset scheme
works" to "therefore build a per-row map." Interleaving rules out offsets; it
says nothing about whether translation is required. Count first.

If your ids genuinely are not valid tokens, then you need a map — and it must be
a **table, not a migration-time printout**, because a caller may arrive with a
stale id days later. Inventory every caller before deciding:

- the MCP tool's **input schema** (`type: "integer"` will reject opaque ids)
- the tool implementation's lookup
- REST controllers and routes
- **view partials** and forms
- integration tests
- **documentation** quoting ids in example commands
- **agents currently holding an id** from an earlier read

That last one has no grep. It is why the map must be a **table, not a
migration-time printout** — a caller may arrive with a stale integer days later.

```ruby
create_table :legacy_checklist_item_ids do |t|
  t.bigint :legacy_id, null: false, index: { unique: true }
  t.string :opaque_id, null: false
end
```

Accept both id types for one release (`["integer", "string"]`), resolve integers
through the map, then narrow.

If you do need generated ids, do not derive them from the integers by any
per-subject offset — ids interleave more than you would guess (in one census six
subjects' ranges overlapped, 24–55 against 41–56). Generate fresh ids and map
per row.

## Timestamps belong to runs, not items

If your existing items carry a `done_at`, resist adding a timestamp field to the
checklist item. `done` is *current state*; timestamped completion is *history*,
and putting the same fact in both layers lets them disagree.

Backfill a **closed run** per subject instead: `ticks` carrying each item's
original `done_at` as `at`, `started_at`/`finished_at` from the earliest and
latest, and an honest `actor_ref` like `"migration"` — do not invent a user. The
current `done` flags carry across unchanged, so nobody's in-flight work moves,
and `last_run` starts answering immediately.

Losing those timestamps is also a defensible choice — just make it explicitly,
rather than letting them disappear quietly.

## While both surfaces are live, audit for ACCOUNTABILITY, not parity

The obvious check during a cutover is item-by-item equality between the old
table and jazari. It will be wrong, and in a way that gets worse the longer it
runs.

Your legacy table has no concept of a run. Jazari does. So a step that was
ticked inside a run that later ended is `done` in the legacy row forever, and
correctly not `done` on the current runbook — the two models disagree about what
`done` *means*, and no amount of copying closes the gap. The only way to make a
parity check pass is to tick items in the current run on the strength of
evidence gathered in a superseded one, which is exactly the lie the run layer
exists to prevent.

So make the gate: **every legacy fact is either present in jazari, or written
down as a known exception with its reason and its date.** Green means "nothing
is unexplained", not "nothing differs". Then retire the audit at the drop rather
than leaving it to alarm on ordinary operator edits — a red check nobody acts on
costs more than it catches.

(From Conductor's cutover: three items ticked in the legacy table on 2026-08-11
belonged to a run that was abandoned, and the agent who found them was right to
refuse to copy them forward.)

## Backfill on the right condition

The trap: creating a runbook row only for records whose runbook **text** is
non-empty. If that column is nullable and checklist items live in their own
table, a record can have a full checklist and no text — and its checklist
vanishes silently.

Backfill on `text present OR items present`.

## Seeded in Ruby is not seeded

Two hosts in a row shipped a `seed!` method that nothing outside their tests ever
called. The recipes existed in Ruby and never in a table, and because a pointer at
a missing recipe resolves to the **empty recipe** rather than raising, the symptom
is an operator reading "this subject has no ritual" as "no ritual is needed."

`db/seeds.rb` does not fix it. Boot typically runs `db:prepare`, which seeds only
on **first create** — an existing database never sees it. Put it in a data
migration, which runs once on every database that has not run it yet:

```ruby
class SeedRecipes < ActiveRecord::Migration[8.0]
  def up = MyRecipes.seed!

  def down
    # Not destructive: by now these rows may carry operator edits.
  end
end
```

Safe on every deploy, because `Jazari::RecipeRegistry.seed!` is create-if-missing
and an operator's edit wins once the row exists. **Grep for the caller before you
believe a seed runs.**

## Verify with row-count equality

Not a spot check:

```ruby
raise "backfill lost items" unless total_jsonb_items == LegacyItem.count
```

Know the target number before you start. If it does not match, **stop** — do not
fix forward.

Wrap the backfill in **its own transaction**, not the migration runner's. A check
that raises after writing has already written; it only guards anything if the
shortfall un-writes what it wrote, and inheriting that from an enclosing
transaction makes the guarantee something a caller can remove without noticing.

```ruby
def up = ActiveRecord::Base.transaction { backfill! }
```

## Ordering

Do not assume `position` is dense. If positions are assigned as
`maximum(:position) + 1`, deletions leave gaps. Order by `position` and re-index
by array order.

## Sequence

1. Add jazari's tables alongside. Change nothing else.
2. Seed recipes; add the queue read path. **This is already useful** — queues
   need no migration of your existing data, so ship it and stop here if you like.
3. Backfill, with the count assertion.
4. Cut the tool over, defaulting `kind` to your existing subject so current calls
   keep working unchanged.
5. Require `expected_revision` — warn for one release, then enforce.
6. A later deploy: drop the old table.

Steps 1–2 are safe and independently valuable. Steps 3–5 need a quiet afternoon
and a verified backup.
