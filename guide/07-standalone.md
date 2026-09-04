# 07 · Standalone SQLite, JSON, and MCP stdio

Standalone Jazari is the same procedure-state domain running against a local
SQLite file. It is an on-demand process: no daemon, scheduler, network listener,
credentials, or command execution is installed.

## Create the database and seed recipes

```bash
jazari recipes seed config/recipes --database .jazari/jazari.sqlite3
```

Files seed missing recipes and never overwrite an existing row. An operator's
stored wording therefore wins over a later seed.

## Call the JSON protocol

Every request names `jazari/v1`, carries a request id, and uses a queue or local
anchor target. Mutations send the revision returned by the read immediately
before them.

```json
{
  "protocol": "jazari/v1",
  "request_id": "read-backup",
  "action": "get",
  "target": {
    "kind": "queue",
    "key": "backup-verify",
    "recipe_id": "backup.verify.v1"
  },
  "arguments": {}
}
```

```bash
jazari call --database .jazari/jazari.sqlite3 --request request.json
```

The schemas and executable examples live in [`protocol/v1/`](../protocol/v1/).
Unknown fields and actions fail as `invalid_request`; domain failures keep the
same closed codes as the embedded handler.

## Connect an MCP client

Configure the client to launch:

```bash
jazari mcp stdio --database /absolute/path/to/jazari.sqlite3 \
  --recipes /absolute/path/to/recipes
```

The server speaks newline-delimited JSON-RPC on stdout and writes nothing else
there. It exposes one `jazari` tool with the existing action enum. The calling
host remains responsible for user consent and authorization before constructing
a target; Jazari records procedure state and evidence but never executes the
procedure.

## SQLite guarantees

- foreign keys are enabled on every connection;
- WAL and a bounded busy timeout are configured for local concurrency;
- stale writes return `revision_conflict`;
- a write that cannot acquire SQLite's database lock within the bounded wait
  returns `storage_busy`, which callers may retry from a fresh read;
- once-per-calendar-day runs use the same UTC identity and null-subject
  collision rule as PostgreSQL;
- opening snapshots, actor attribution, closed-run behavior, and operator-owned
  recipe edits are replayed from the shared conformance fixtures.

Standalone anchor targets use `"scope_type": "local"`. Embedded Rails hosts
continue to register and authorize their own anchor scopes; JSON input cannot
alter that registry.
