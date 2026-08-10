# Releasing jazari

Every shippable change gets a full release — version, changelog, tag, gem.
Don't stop at committing.

This lives at the repo root rather than under `docs/`, because `docs/` is the
GitHub Pages directory and holds `index.html` only.

## 1. Bump the version

- `lib/jazari/version.rb` — `VERSION = "x.y.z"`
- `CHANGELOG.md` — a `## [x.y.z]` entry describing what changed

Both are enforced in CI. A tag whose version disagrees with `Jazari::VERSION`
fails the release, and so does a version with no changelog entry — a release
nobody can read is not a release.

### What counts as which bump

This gem's public contract is wider than its method signatures. Treat these as
**breaking** even though they look small:

- adding or removing an **error code** — hosts translate the closed taxonomy
- changing the **shape of a `ResolvedRunbook`** or a handler reply
- changing how a **revision** is computed — every outstanding revision goes
  stale at once
- changing the **schema the generator emits**, or tightening a column
- adding a **required** config port

## 2. Verify locally

```bash
bundle exec rake        # boundary check, then the suite — must be green
gem build jazari.gemspec
```

PostgreSQL must be running. The suite exercises the migration the gem ships,
so a green run means the schema is real, not approximated.

**Read the boundary output.** It is the check that stops a host product name
leaving in a published package, and release is the one irreversible moment.

## 3. Commit, tag, push

```bash
git add -A
git commit -m "release: vX.Y.Z"
git tag -a vX.Y.Z -m "jazari X.Y.Z"
git push origin main
git push origin vX.Y.Z
```

Pushing the `v*` tag triggers `.github/workflows/release.yml`, which verifies
the tag against `Jazari::VERSION`, verifies the changelog entry, runs the gate
against a real PostgreSQL service, builds, and **pushes to RubyGems**.

**Do not `gem push` by hand** — it collides with the CI push, which then fails
because the version already exists.

## 4. Confirm

```bash
gem info jazari --remote        # the new version is listed
```

Then bump any host that pins a git `ref:` — while the gem is unreleased, hosts
resolve it from this repo by SHA, and those refs do not move themselves.

## 5. Announce (optional, for notable releases)

A library gem does not need a tweet for every patch. For a release that changes
what the gem *is* — a new layer, a new guarantee — say so, and link the landing
page rather than the repo.

---

## Pre-1.0

Until `1.0.0`, minor versions may break. Say so plainly in the changelog rather
than pretending otherwise; the hosts adopting this gem are all in one fleet and
can be migrated deliberately.

The move to `1.0.0` should wait until at least two hosts have run the Run layer
against real traffic. Idempotency, evidence, and the revision guard are the
claims most likely to be wrong in a way only production reveals — the first
adoption already found five bugs that no amount of unit testing had surfaced.

## This ritual is itself a candidate recipe

Everything above is a numbered procedure with verifiable steps and a stated
hidden truth ("do not `gem push` by hand"). That is exactly what this gem
stores. A host that adopts jazari can seed this file as a recipe and open a run
per release — which is the honest test of whether the format is any good.
