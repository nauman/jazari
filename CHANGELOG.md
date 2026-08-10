# Changelog

All notable changes are recorded here. The release workflow REFUSES to publish
a version with no entry — see RELEASING.md.

Pre-1.0: minor versions may break. The public contract includes the error
codes, the resolved-value shape, how revisions are computed, and the schema the
generator emits — changes to any of those are breaking even when the method
signatures do not move.

## [0.1.0] - 2026-08-10

First release. Proven against one host adoption.

- Four layers: recipe (the canon), runbook (per-subject override), queue
  (a stable name for a ritual), run (one execution with evidence).
- Per-recipe idempotency (`unrestricted` / `once_per_calendar_day`), enforced by
  a partial unique index over a `COALESCE`d polymorphic subject and a UTC day.
- Revision guards on every mutation; digest-based revisions for defaults.
- Runs are bound to the canon they opened against via a checklist snapshot.
- `Jazari::Mcp::Handler` — transport-neutral action dispatch; host owns tool identity.
- `rails g jazari:install` — host-adopted migration; the gem never auto-appends.
- PostgreSQL only. The suite runs the migration the gem ships.
- `Jazari.forget_subject` — host-called cleanup; runs deliberately survive.
- Railtie so models autoload in a host (the gem was unusable without it).
- Per-table name overrides, for hosts adopting tables they already have.

### Found by the first host adoption

Five defects that no amount of unit testing had surfaced, each now
regression-tested — every one a place the gem assumed it owned something the
host actually owns:

- models never autoloaded in a real application
- read and write paths resolved anchors differently
- host resolvers were not told whether they may create, so reads wrote
- `reset` assumed the gem's own anchor class and left host-owned orphans
- the recipe registry could disagree with itself across a shim boundary
