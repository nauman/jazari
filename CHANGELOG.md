# Changelog

## [Unreleased]

Initial implementation. Not yet released to RubyGems.

- Four layers: recipe (the canon), runbook (per-subject override), queue
  (a stable name for a ritual), run (one execution with evidence).
- Per-recipe idempotency (`unrestricted` / `once_per_calendar_day`), enforced by
  a partial unique index over a `COALESCE`d polymorphic subject and a UTC day.
- Revision guards on every mutation; digest-based revisions for defaults.
- Runs are bound to the canon they opened against via a checklist snapshot.
- `Jazari::Mcp::Handler` — transport-neutral action dispatch; host owns tool identity.
- `rails g jazari:install` — host-adopted migration; the gem never auto-appends.
- PostgreSQL only. The suite runs the migration the gem ships.
