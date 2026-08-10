# Contributing

Thanks for looking.

## Running the suite

PostgreSQL is required — the gem's guarantees rely on `jsonb`, `timestamptz`,
CHECK constraints, and a partial unique index, so a portable in-memory adapter
would prove a schema we do not ship.

```bash
bundle install
bundle exec rake        # boundary check, then tests
```

The suite creates and migrates `jazari_test` itself. Override with
`JAZARI_TEST_DATABASE`.

## The boundary check

`rake boundary` runs before the tests and fails if:

- a file under `lib/` or `app/` is not inside `module Jazari`, or
- the test suite names a constant outside the gem, Ruby core, ActiveRecord,
  Minitest, or the single `DummySubject` fixture.

This is not style enforcement. The gem is useful *because* it is
product-agnostic; a test that reaches for a real application model means the
boundary has broken. If you need a subject in a test, use `DummySubject`.

## What a good change looks like

- A behaviour change comes with a test that fails without it.
- Schema changes update `lib/generators/jazari/install/templates/` — the suite
  runs that migration, so there is no second schema to update.
- Errors belong to the closed taxonomy in `lib/jazari/errors.rb`. If you need a
  new one, say why in the PR — every code is part of the public contract.

## Scope

Jazari holds the *state* of a procedure. It deliberately does not execute
anything — no SSH, no shelling out, no job runner. Proposals to add execution
are better directed at composing with an execution framework.
