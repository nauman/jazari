# Changelog

All notable changes are recorded here. The release workflow REFUSES to publish
a version with no entry — see RELEASING.md.

Pre-1.0: minor versions may break. The public contract includes the error
codes, the resolved-value shape, how revisions are computed, and the schema the
generator emits — changes to any of those are breaking even when the method
signatures do not move.

## [0.5.0] - 2026-08-12

### Added

- **Execution-scoped actor identity.** Runs now require an opaque `actor_ref`,
  with explicit values taking precedence over a configured trusted-system
  default. Ticks and evidence inherit the run actor unless explicitly
  attributed otherwise.
- Evidence records now retain `actor_ref`, making it possible to answer who or
  what performed each procedure step without giving Jazari access to actor
  objects.
- MCP evidence declarations and public examples now expose the actor contract.
- Public guides and the landing page now document actor attribution and
  RecipeFiles load, seed, dump, and drift workflows.

### Compatibility

- Existing explicit `actor_ref` calls continue to work unchanged.
- MCP run start continues to require an explicit actor identity; subsequent
  tick and evidence calls may inherit the actor from the open run.

## [0.4.0] - 2026-08-11

### Added

- **`Jazari::RecipeFiles` — recipes as YAML or JSON, without files silently
  overwriting operators.**

  Nothing ever forbade files: `RecipeRegistry.seed!` takes plain hashes, so
  `seed!(YAML.load_file(…))` already worked. What was missing was everything
  that makes it *safe*.

  - **`load(path)`** — a file or a directory of `.yml` / `.yaml` / `.json`.
    Accepts one recipe, a list, or a list under a `recipes:` key. It validates
    at LOAD, which is the whole reason it exists rather than "just call
    `YAML.load_file`": an unknown key is a typo, and a typo that loads silently
    becomes a recipe resolving to something nobody wrote. Unknown keys, missing
    topics, bad `run_policy`, duplicate ids and malformed YAML all raise, naming
    the file.
  - **`dump(dir)`** — writes what is actually stored back out, one file per
    recipe. Without this the loop never closes: an operator's runtime fix could
    not be reviewed or committed, so runtime editing would quietly become the
    thing you avoid rather than the thing the design is built around.
  - **`drift(entries)`** — which stored recipes disagree with their file, and in
    which fields. **Reported, never applied.**

  **Files seed; they do not sync.** `seed!` stays create-if-missing, so a file
  never overwrites a row an operator edited. That is the same rule the runbook
  layer already follows — a customisation diverges rather than rebasing, because
  silently overwriting a deliberate edit with a change nobody saw is the worst
  available outcome. Applying files on every deploy would do exactly that, one
  layer up. The cost is drift, so drift is made visible instead of resolved.

  One place the loader is deliberately **stricter than the API**: a malformed
  checklist id is an error rather than a fixup. `Checklist.normalize` replaces an
  unusable id with a generated one, which is right when an id is absent and
  opaque — but in a file someone wrote it, MCP addresses the step by it, and
  documentation quotes it. Swapping it for a random token would create exactly
  the file-versus-row disagreement this loader exists to prevent.

### Fixed

- **The boundary check read heredoc bodies as code.** It stripped `"…"` and
  `'…'` on the stated principle that a capitalised word inside a string is data,
  but a fixture written as `<<~YML` had its own prose reported as constant
  references. Heredoc bodies are now skipped. Verified still catching a planted
  breach.

## [0.3.0] - 2026-08-11

### Added

- **`origin` on the runbook — provenance, so divergence means something.**
  `custom?` answers "does a row exist", which a host adopting jazari cannot use
  as a divergence signal: a backfill materializes a row for every subject at
  once, so the morning after a migration everything reads as diverged and the
  signal carries no information. Comparing content against the recipe does not
  separate them either — a backfilled runbook *genuinely* differs, because it
  carries the steps that subject actually had. Only provenance can.

  `origin` is a nullable, host-defined string saying **why the row exists**.
  `ResolvedRunbook` gains `#origin`, plus `#inherited?` (a row something claims
  to have manufactured) and `#diverged?` (a row nobody claims, i.e. someone
  decided it). `Jazari.customize` takes an optional `origin:`.

  Two behaviours make the marker honest rather than decorative:

  - **`customize` restates it, defaulting to nil.** Rewriting a procedure is a
    decision, so an operator edit clears an inherited marker — the claim about
    how the row came to exist stops being true the moment someone edits it.
  - **Item operations preserve it.** `check_item`, `add_item` and `remove_item`
    leave `origin` untouched, because performing a procedure is not rewriting
    it. Without this, the first person to tick a box would silently convert a
    migration artifact into a deliberate divergence.

  Raised by a host adoption, where the backfill would otherwise have made six
  of six subjects read as diverged on day one.

### Changed

- **`ResolvedRunbook` carries a new member (`origin`).** Positional
  construction and exhaustive destructuring break; keyword construction and
  member access do not. It defaults to nil, so hosts that ignore it are
  unaffected.

### Migration

Already installed? `rails g jazari:upgrade` copies the one additive, nullable
column. It is safe to run ahead of any code that writes it — NULL is truthful
for every existing row, meaning "this predates provenance". New installs get
the column from `jazari:install`.

## [0.2.1] - 2026-08-10

### Fixed

- **Table names are resolved lazily, not assigned at class-definition time.**
  The binding previously depended on load order: under Zeitwerk a host's
  `Jazari.configure` runs before the model constants autoload, so the
  assignment never happened and the models silently kept the gem's default
  names. A host that had adopted *existing* tables then queried tables that did
  not exist. Found by a third host adoption.

## [0.2.0] - 2026-08-10

### Added

- **`Jazari::Mcp::Actions`** — every action declared as data (`scope`, `effect`,
  `confirm`, parameter schemas, summary), with `schema_fragment` for merging into
  a host's own MCP tool. A host with an existing MCP surface keeps its tool name,
  envelope, dispatch, and permissions, and calls `Jazari.*` directly — no
  coupling to this gem's handler or reply shape.
- `Jazari::Mcp::Actions.summaries` for a tool description or paired skill.

### Changed

- **The MCP layer is now genuinely optional.** Descriptors load with the gem;
  the dispatcher does not. `require "jazari/mcp/handler"` to opt in.
- `Mcp::Handler` validates and scopes against the same declarations, so a
  published schema and the implemented behaviour cannot drift. A test asserts the
  handler dispatches every declared action.

### Fixed

- `mcp/handler.rb` now requires `mcp/actions`. With the layer opt-in, a host
  requiring the handler alone would have raised `NameError`.

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
