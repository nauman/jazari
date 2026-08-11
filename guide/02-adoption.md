# 02 · Adoption

```ruby
gem "jazari", "~> 0.1"
```

```bash
bin/rails generate jazari:install
bin/rails db:migrate
```

The generator copies **one migration**. Jazari never auto-appends migrations —
a shared operations table appearing in someone's next `db:migrate` unasked is
how a gem loses trust in a production fleet.

PostgreSQL is required: `jsonb`, `timestamptz`, four CHECK constraints, and a
partial unique index over a `COALESCE`d polymorphic subject.

## Configure at boot

```ruby
Jazari.configure do |c|
  c.actor_ref            = -> { "system:nightly-backup" } # trusted default only
  c.anchor_scopes        = { "Tree" => resolver }      # see guide 03
  c.on_subject_destroyed = ->(subject) { }             # optional hook
end
```

`configure` validates and returns; a scope it cannot understand fails at boot
rather than at the first call.

Pass explicit actor references for human, agent, or delegated work. They always
override the configured default. Ticks and evidence inherit the run actor when
omitted; opening a run without an actor requires the configured default.

## Adopting onto tables you already have

If you already run something like this, you do not have to rename live tables in
the same deploy as a cut-over — which is the change most likely to go wrong.

```ruby
Jazari.configure do |c|
  c.table_prefix = "myapp_"
  c.table_names  = {
    runbooks: "myapp_runbooks",
    recipes:  "myapp_runbook_recipes",   # names rarely follow one prefix
    anchors:  "myapp_runbook_anchors",
    runs:     "myapp_runs"
  }
end
```

Any key you omit falls back to the prefix.

> **`table_prefix` is process-global.** ActiveRecord table names are class
> state, so this is a boot-time setting for the whole process — not per-request,
> per-thread, or per-tenant. Two hosts in one process cannot hold different
> prefixes.

Because the binding is global, assert it took effect rather than trusting it:

```ruby
raise "jazari models not loaded" unless Jazari.models_loaded?
```

Without that, a `configure` that runs too early silently leaves the models on
the gem's default names, and you find out via a missing-table error in
production.

## Seed your own recipes

```ruby
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
```

`seed!` is **create-if-missing**. Reseeding never overwrites an operator's edit,
because once a recipe exists the operator owns it. Safe to run on every deploy.

Give checklist items **stable ids** in your seeds (`"dump"`, not a generated
token) — an item's id is how MCP addresses it, and a stable id survives editing
the text.

## Targets

Authorize first, then construct exactly one:

```ruby
Jazari::RecordTarget.new(runbookable: site,
  public_reference: { kind: "site", site: site.slug }, recipe_id: "site.v1")

Jazari::QueueTarget.new(queue: "backup-verify",
  public_reference: { kind: "queue" }, recipe_id: "backup.verify.v1")

Jazari::AnchorTarget.new(scope_type: "Tree", scope_id: 7, key: "node-x",
  public_reference: { kind: "node" }, recipe_id: "node.v1")
```

`public_reference` is echoed back in every result. Put in it exactly what you
are willing to show a caller — it crosses the wire.

## Deleting a subject

No cross-database foreign key is claimed, so there is no cascade. Call in:

```ruby
class Site < ApplicationRecord
  after_commit :forget_jazari, on: :destroy
  def forget_jazari = Jazari.forget_subject(self)
end
```

That removes the override. **Runs are preserved** — a run records something that
happened, and deleting the subject does not un-happen it.

## Errors

A closed set, translated by you into your own envelope:

`target_not_found` · `invalid_runbook` · `revision_conflict` · `item_not_found`
· `read_only_target` · `run_closed`

Unauthorized, unknown, deleted, and type-mismatched input all collapse to
`target_not_found` on purpose: guessing a target must not reveal whether it
exists.
