# frozen_string_literal: true

require_relative "test_helper"

class RunsTest < Minitest::Test
  def setup
    Jazari::Run.delete_all
    Jazari::RecipeRecord.delete_all
    DummySubject.delete_all

    Jazari::RecipeRegistry.seed!([
      { id: "daily.v1", topic: "Daily ritual", run_policy: "once_per_calendar_day",
        checklist: [ { id: "step-a", text: "Prove it", done: false } ] },
      { id: "adhoc.v1", topic: "Ad-hoc ritual", run_policy: "unrestricted",
        checklist: [ { id: "step-a", text: "Do it", done: false } ] }
    ])
  end

  def queue(recipe_id)
    Jazari::QueueTarget.new(queue: "q", public_reference: { kind: "queue" }, recipe_id: recipe_id)
  end

  def record_target(subject, recipe_id)
    Jazari::RecordTarget.new(runbookable: subject, public_reference: { kind: "dummy" }, recipe_id: recipe_id)
  end

  # --- idempotency ------------------------------------------------------

  def test_daily_queue_run_is_idempotent_within_the_utc_day
    a = Jazari::Runs.open(target: queue("daily.v1"), actor_ref: "agent:1", now: Time.utc(2026, 8, 10, 3, 0))
    b = Jazari::Runs.open(target: queue("daily.v1"), actor_ref: "agent:2", now: Time.utc(2026, 8, 10, 21, 0))

    assert a[:created], "first call opens a run"
    refute b[:created], "second call the same UTC day must reuse"
    assert b[:idempotent_reuse]
    assert_equal a[:run].id, b[:run].id
    assert_equal 1, Jazari::Run.count
  end

  def test_queue_runs_are_constrained_despite_null_subject
    # The bug this guards: a plain unique index does not constrain NULL subjects,
    # because NULL != NULL. COALESCE is what makes queue runs unique at all.
    Jazari::Runs.open(target: queue("daily.v1"), actor_ref: "a", now: Time.utc(2026, 8, 10, 1, 0))
    Jazari::Runs.open(target: queue("daily.v1"), actor_ref: "b", now: Time.utc(2026, 8, 10, 2, 0))
    assert_equal 1, Jazari::Run.where(subject_type: nil).count
  end

  def test_a_new_utc_day_opens_a_new_run
    Jazari::Runs.open(target: queue("daily.v1"), actor_ref: "a", now: Time.utc(2026, 8, 10, 23, 59))
    second = Jazari::Runs.open(target: queue("daily.v1"), actor_ref: "a", now: Time.utc(2026, 8, 11, 0, 1))
    assert second[:created]
    assert_equal 2, Jazari::Run.count
  end

  def test_unrestricted_recipes_open_every_time
    3.times { |i| Jazari::Runs.open(target: queue("adhoc.v1"), actor_ref: "a", now: Time.utc(2026, 8, 10, i + 1)) }
    assert_equal 3, Jazari::Run.count
  end

  def test_distinct_subjects_do_not_collide_on_the_same_day
    one = DummySubject.create!(name: "one")
    two = DummySubject.create!(name: "two")
    Jazari::Runs.open(target: record_target(one, "daily.v1"), actor_ref: "a", now: Time.utc(2026, 8, 10, 3))
    Jazari::Runs.open(target: record_target(two, "daily.v1"), actor_ref: "a", now: Time.utc(2026, 8, 10, 3))
    assert_equal 2, Jazari::Run.count
  end

  # --- lifecycle --------------------------------------------------------

  def test_tick_requires_the_current_revision
    run = Jazari::Runs.open(target: queue("adhoc.v1"), actor_ref: "a")[:run]
    Jazari::Runs.tick(run: run, expected_revision: run.lock_version,
                      item_id: "step-a", done: true, actor_ref: "a")

    error = assert_raises(Jazari::RevisionConflict) do
      Jazari::Runs.tick(run: run, expected_revision: 0,
                        item_id: "step-a", done: true, actor_ref: "a")
    end
    assert_equal "revision_conflict", error.code
  end

  def test_tick_rejects_an_unknown_item
    run = Jazari::Runs.open(target: queue("adhoc.v1"), actor_ref: "a")[:run]
    assert_raises(Jazari::ItemNotFound) do
      Jazari::Runs.tick(run: run, expected_revision: run.lock_version,
                        item_id: "nope", done: true, actor_ref: "a")
    end
  end

  def test_a_closed_run_cannot_be_ticked
    run = Jazari::Runs.open(target: queue("adhoc.v1"), actor_ref: "a")[:run]
    Jazari::Runs.close(run: run, expected_revision: run.lock_version, outcome: "completed")

    error = assert_raises(Jazari::RunClosed) do
      Jazari::Runs.tick(run: run, expected_revision: run.lock_version,
                        item_id: "step-a", done: true, actor_ref: "a")
    end
    assert_equal "run_closed", error.code
  end

  def test_evidence_kinds_are_bounded
    run = Jazari::Runs.open(target: queue("adhoc.v1"), actor_ref: "a")[:run]
    Jazari::Runs.attach_evidence(run: run, expected_revision: run.lock_version,
                                 item_id: "step-a", kind: "sha", value: "deadbeef")
    assert_equal 1, run.reload.evidence.length

    assert_raises(Jazari::InvalidRunbook) do
      Jazari::Runs.attach_evidence(run: run, expected_revision: run.lock_version,
                                   item_id: "step-a", kind: "whatever", value: "x")
    end
  end

  def test_last_answers_did_it_complete
    run = Jazari::Runs.open(target: queue("daily.v1"), actor_ref: "a", now: Time.utc(2026, 8, 10, 3))[:run]
    Jazari::Runs.close(run: run, expected_revision: run.lock_version, outcome: "completed")

    last = Jazari::Runs.last(target: queue("daily.v1"))
    assert_equal "completed", last.outcome
    assert last.closed?
  end

  # --- recipes ----------------------------------------------------------

  def test_reseeding_never_overwrites_an_operator_edit
    Jazari::RecipeRecord.find_by(recipe_id: "daily.v1").update!(topic: "Operator's own words")
    Jazari::RecipeRegistry.seed!([ { id: "daily.v1", topic: "Back to the default", checklist: [] } ])
    assert_equal "Operator's own words", Jazari::RecipeRecord.find_by(recipe_id: "daily.v1").topic
  end

  def test_a_missing_recipe_resolves_empty_and_writes_nothing
    before = Jazari::RecipeRecord.count
    recipe = Jazari::RecipeRegistry.fetch("does.not.exist")
    assert_equal "core.empty.v1", recipe.id
    assert_equal before, Jazari::RecipeRecord.count
  end

  def test_editing_a_recipe_changes_its_digest
    first = Jazari::RecipeRegistry.fetch("daily.v1").digest
    Jazari::RecipeRecord.find_by(recipe_id: "daily.v1").update!(topic: "changed")
    refute_equal first, Jazari::RecipeRegistry.fetch("daily.v1").digest
  end
end

# ── regressions from the chunk-1 review (2026-08-10) ──────────────────────

class RunsReviewRegressionsTest < Minitest::Test
  def setup
    Jazari::Run.delete_all
    Jazari::RecipeRecord.delete_all
    Jazari::RecipeRegistry.seed!([
      { id: "daily.v1", topic: "Daily", run_policy: "once_per_calendar_day",
        checklist: [ { id: "step-a", text: "A", done: false } ] },
      { id: "adhoc.v1", topic: "Ad-hoc", run_policy: "unrestricted",
        checklist: [ { id: "step-a", text: "A", done: false } ] }
    ])
  end

  def queue(recipe_id)
    Jazari::QueueTarget.new(queue: "q", public_reference: {}, recipe_id: recipe_id)
  end

  # Finding 5 — a run is bound to the canon it opened against.
  def test_an_in_flight_run_still_ticks_its_own_steps_after_the_recipe_changes
    run = Jazari::Runs.open(target: queue("adhoc.v1"), actor_ref: "a")[:run]
    Jazari::RecipeRecord.find_by(recipe_id: "adhoc.v1")
      .update!(checklist: [ { "id" => "step-b", "text" => "B", "done" => false } ])

    Jazari::Runs.tick(run: run, expected_revision: run.lock_version,
                      item_id: "step-a", done: true, actor_ref: "a")
    assert_equal 1, run.reload.ticks.length, "the run must still tick its own step"
  end

  def test_an_in_flight_run_rejects_steps_added_after_it_opened
    run = Jazari::Runs.open(target: queue("adhoc.v1"), actor_ref: "a")[:run]
    Jazari::RecipeRecord.find_by(recipe_id: "adhoc.v1")
      .update!(checklist: [ { "id" => "step-b", "text" => "B", "done" => false } ])

    assert_raises(Jazari::ItemNotFound) do
      Jazari::Runs.tick(run: run, expected_revision: run.lock_version,
                        item_id: "step-b", done: true, actor_ref: "a")
    end
  end

  # Finding 2 — a unique violation we do not own must not be read as reuse.
  def test_a_foreign_unique_violation_is_not_swallowed_for_an_unrestricted_recipe
    Jazari::Run.connection.execute("CREATE UNIQUE INDEX host_actor_idx ON jazari_runs (actor_ref)")
    Jazari::Runs.open(target: queue("adhoc.v1"), actor_ref: "solo")
    assert_raises(ActiveRecord::RecordNotUnique) do
      Jazari::Runs.open(target: queue("adhoc.v1"), actor_ref: "solo")
    end
  ensure
    Jazari::Run.connection.execute("DROP INDEX IF EXISTS host_actor_idx")
  end

  # The harder case the first version of this test missed: a DAILY recipe takes
  # the reuse path, so a foreign violation could be masked there. Different
  # days, so our own index is NOT the one being violated.
  def test_a_foreign_unique_violation_is_not_masked_for_a_daily_recipe
    Jazari::Run.connection.execute("CREATE UNIQUE INDEX host_actor_idx ON jazari_runs (actor_ref)")
    Jazari::Runs.open(target: queue("daily.v1"), actor_ref: "solo", now: Time.utc(2026, 8, 10, 3))

    error = assert_raises(ActiveRecord::RecordNotUnique) do
      Jazari::Runs.open(target: queue("daily.v1"), actor_ref: "solo", now: Time.utc(2026, 8, 11, 3))
    end
    refute_match(/once_per_day/, error.message.to_s.split("\n").first.to_s)
  ensure
    Jazari::Run.connection.execute("DROP INDEX IF EXISTS host_actor_idx")
  end

  # Finding 2b — a resolver returning nil must fail closed, not silently
  # produce a subject-less run that looks like a legitimate queue run.
  def test_an_anchor_resolver_returning_nil_fails_closed
    Jazari.configure { |c| c.anchor_scopes = { "Tree" => ->(_t) { nil } } }
    target = Jazari::AnchorTarget.new(scope_type: "Tree", scope_id: 1, key: "gone",
                                      public_reference: {}, recipe_id: "adhoc.v1")
    assert_raises(Jazari::TargetNotFound) { Jazari::Runs.open(target: target, actor_ref: "a") }
    assert_equal 0, Jazari::Run.count
  end

  def test_an_anchor_resolver_returning_a_non_record_fails_closed
    Jazari.configure { |c| c.anchor_scopes = { "Tree" => ->(_t) { Object.new } } }
    target = Jazari::AnchorTarget.new(scope_type: "Tree", scope_id: 1, key: "bad",
                                      public_reference: {}, recipe_id: "adhoc.v1")
    assert_raises(Jazari::TargetNotFound) { Jazari::Runs.open(target: target, actor_ref: "a") }
  end

  # Finding 4 — a run with no snapshot is a migration defect, and says so
  # rather than rejecting every tick as an unknown item.
  def test_a_run_without_a_snapshot_reports_a_backfill_defect
    run = Jazari::Runs.open(target: queue("adhoc.v1"), actor_ref: "a")[:run]
    run.update_column(:checklist_snapshot, [])
    error = assert_raises(Jazari::InvalidRunbook) do
      Jazari::Runs.tick(run: run.reload, expected_revision: run.lock_version,
                        item_id: "step-a", done: true, actor_ref: "a")
    end
    assert_match(/backfill/, error.message)
  end

  # Finding 4 — an unregistered anchor scope fails closed.
  def test_an_unregistered_anchor_scope_is_rejected
    Jazari.configure { |c| c.anchor_scopes = {} }
    target = Jazari::AnchorTarget.new(scope_type: "Unregistered", scope_id: 1,
                                      key: "k", public_reference: {}, recipe_id: "adhoc.v1")
    assert_raises(Jazari::TargetNotFound) do
      Jazari::Runs.open(target: target, actor_ref: "a")
    end
  end

  # Finding 6 — the documented public API exists.
  def test_the_documented_public_api_is_callable
    result = Jazari.open_run(target: queue("adhoc.v1"), actor_ref: "a")
    run = result[:run]
    Jazari.tick(run: run, expected_revision: run.lock_version,
                item_id: "step-a", done: true, actor_ref: "a")
    Jazari.attach_evidence(run: run.reload, expected_revision: run.lock_version,
                           item_id: "step-a", kind: "sha", value: "abc123")
    Jazari.close_run(run: run.reload, expected_revision: run.lock_version, outcome: "completed")
    assert_equal "completed", Jazari.last_run(target: queue("adhoc.v1")).outcome
  end

  # Finding 3 — a configured table prefix reaches the models.
  def test_a_configured_table_prefix_reaches_the_models_and_is_queryable
    original = Jazari.config.table_prefix
    Jazari::Run.connection.execute("CREATE TABLE tenant_jazari_runs AS SELECT * FROM jazari_runs")

    Jazari.configure { |c| c.table_prefix = "tenant_jazari_" }
    assert_equal "tenant_jazari_runs", Jazari::Run.table_name
    # Prove the binding is real by querying through it, not just reading an attr.
    assert_equal 0, Jazari::Run.count
    assert Jazari.models_loaded?, "the binding must report whether it took effect"
  ensure
    Jazari.configure { |c| c.table_prefix = original }
    Jazari::Run.connection.execute("DROP TABLE IF EXISTS tenant_jazari_runs")
    assert_equal "#{original}runs", Jazari::Run.table_name
  end
end
