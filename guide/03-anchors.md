# 03 · Anchors — subjects that are not rows

Some things you want a procedure for are not ActiveRecord records: a node in a
JSON tree, a file path, a DNS zone, a cron schedule.

An **anchor** gives such a subject a stable relational identity, so a runbook
can attach to it like anything else.

```ruby
Jazari::AnchorTarget.new(
  scope_type: "Tree", scope_id: workspace.id, key: "node-x",
  public_reference: { kind: "node" }, recipe_id: "node.v1"
)
```

`scope_type` + `scope_id` say *which container*; `key` says *which thing inside
it*.

## Register the scope

Unregistered scopes fail closed:

```ruby
Jazari.configure { |c| c.anchor_scopes = { "Tree" => nil } }
```

`nil` means "use the gem's own anchors table" — fine when the subject has no
existence of its own.

## Supplying your own resolver

Supply a lambda when the anchor lives somewhere jazari cannot see, or your table
has columns the gem knows nothing about:

```ruby
c.anchor_scopes = {
  "Tree" => lambda do |target, create|
    workspace = Workspace.find_by(id: target.scope_id)
    raise Jazari::TargetNotFound, "unknown workspace" unless workspace
    raise Jazari::TargetNotFound, "unknown node" unless node_in?(workspace, target.key)

    if create
      MyAnchor.create_or_find_by!(workspace: workspace, node_id: target.key)
    else
      MyAnchor.find_by(workspace: workspace, node_id: target.key)
    end
  end
}
```

### The contract, and why each part exists

**`create` tells you whether you may materialise.** It is `false` on every read.
A resolver that always creates will materialise an anchor on `resolve` — which
breaks the rule that reading a default writes nothing, and quietly fills your
table with rows for subjects nobody ever customised.

**Return a persisted record, or nil, or raise.** Anything else fails closed. A
`nil` on a *write* raises `target_not_found` rather than proceeding.

**Distinguish "invalid" from "absent" — they are not the same.**

| Situation | Do |
|---|---|
| the container or key is **invalid** | `raise Jazari::TargetNotFound` |
| valid, but no anchor **yet** | return `nil` |

Collapsing these is the subtlest mistake available here. If an unknown node
returns `nil`, it resolves to a default and looks like a perfectly ordinary
uncustomised subject — so a typo'd id silently succeeds instead of failing.

**Validate against the authority, not a projection.** If you keep a search index
or cache of your tree, do not consult it here. A rebuildable projection must not
decide whether durable user intent may exist.

## Lifecycle

An anchor is created **only** when a customisation is materialised, and
destroyed with it on `reset` — including anchors of your own class. Nothing here
assumes the gem owns the anchor model.
