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

## Item ids are load-bearing

Integer primary keys leak further than you expect. Inventory every caller — not
just the obvious one:

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

**Do not derive the opaque id from the integer.** Ids interleave across subjects
far more than you would guess — in one census six subjects' ranges overlapped
(24–55 against 41–56), so no per-subject offset scheme can work. Generate fresh
ids and map per row.

## Backfill on the right condition

The trap: creating a runbook row only for records whose runbook **text** is
non-empty. If that column is nullable and checklist items live in their own
table, a record can have a full checklist and no text — and its checklist
vanishes silently.

Backfill on `text present OR items present`.

## Verify with row-count equality

Not a spot check:

```ruby
raise "backfill lost items" unless total_jsonb_items == LegacyItem.count
```

Know the target number before you start. If it does not match, **stop** — do not
fix forward.

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
