# 05 · MCP

Procedures are most useful when an agent can call them by name. Jazari ships a
transport-neutral handler; **you own the tool.**

```ruby
Jazari::Mcp::Handler.new.call(action: "get", target: target)
# => { ok: true, state: "default", topic: "...", progress: {...}, last_run: {...} }
```

## Why the gem does not ship a tool

Tool identity is product identity. Your tool has your name, your subject
vocabulary, and your permissions — `myapp_runbook`, not `jazari_runbook`. Two
apps sharing this handler still present two different tools.

The handler also never sees an actor. **You authorize, then construct the
target**, then call. That ordering is the whole security model.

```ruby
def call(input)
  target = authorized_target(input) or return not_found   # you
  reply  = Jazari::Mcp::Handler.new.call(                 # gem
    action: input["action"], target: target, arguments: input
  )
  reply[:ok] ? ok(reply) : fail(reply[:error])            # you
end
```

## Actions

Read: `get`, `last_run`
Write: `set`, `add_item`, `remove_item`, `check_item`, `reset`
Runs: `start`, `tick`, `evidence`, `finish`

```ruby
Jazari::Mcp::Handler.actions_for("read")   # => ["get", "last_run"]
```

Advertise only what the granted scope may call. A read-scoped connection should
not see mutations in its tool list at all — offering them and then refusing is a
worse experience than not offering them.

## One flat tool, not one per verb

Keep a single `action`-enum tool. Agents deal badly with a dozen near-identical
tools, and a flat enum keeps the whole surface legible in one schema.

Put the *operating guidance* in a paired skill rather than the input schema —
when to open a run versus just read, what evidence to attach, that queues are
advisory.

## Errors cross as codes

```jsonc
{ "ok": false, "error": "revision_conflict" }
```

Never a message. A message can disclose a record, a query, or whether a target
exists. `target_not_found` covers unknown, unauthorized, and deleted alike, so
guessing reveals nothing.

## Two things worth annotating

`reset` is destructive and requires `confirm: true` — it discards an operator's
customisation. `set` may overwrite; annotate it conservatively.

Everything else is either read-only or an additive write.
