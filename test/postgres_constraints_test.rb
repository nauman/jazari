# frozen_string_literal: true

require_relative "test_helper"

# These prove the constraints the gem SHIPS, not a convenience schema. Every
# one of them was unverifiable while the suite ran on another adapter.
class PostgresConstraintsTest < Minitest::Test
  def setup
    Jazari::Run.delete_all
    Jazari::RecipeRecord.delete_all
    Jazari.configure { |c| c.table_prefix = "jazari_"; c.anchor_scopes = {} }
    Jazari::RecipeRegistry.seed!([
      { id: "daily.v1", topic: "D", run_policy: "once_per_calendar_day",
        checklist: [ { id: "a", text: "A", done: false } ] }
    ])
  end

  def queue = Jazari::QueueTarget.new(queue: "q", public_reference: {}, recipe_id: "daily.v1")

  # THE one that mattered: Ruby computes started_on as now.utc.to_date, and
  # Postgres independently CHECKs it against (started_at AT TIME ZONE 'UTC')::date.
  # If those ever disagree, every insert fails in production. Prove they agree,
  # including across the UTC midnight boundary and from a non-UTC input.
  def test_ruby_and_postgres_agree_on_the_utc_day
    [
      Time.utc(2026, 8, 10, 0, 0, 0),
      Time.utc(2026, 8, 10, 23, 59, 59),
      Time.new(2026, 8, 10, 20, 30, 0, "-07:00"),   # non-UTC Time
      Time.new(2026, 8, 11, 9, 15, 0, "+09:00")     # crosses the UTC day backwards
    ].each_with_index do |moment, i|
      Jazari::RecipeRegistry.seed!([ { id: "r#{i}.v1", topic: "T", checklist: [] } ])
      target = Jazari::QueueTarget.new(queue: "q", public_reference: {}, recipe_id: "r#{i}.v1")
      run = Jazari::Runs.open(target: target, actor_ref: "a", now: moment)[:run]

      assert_equal moment.utc.to_date, run.started_on,
        "Ruby must derive the UTC day for #{moment.inspect}"
    end
  end

  def test_postgres_rejects_a_started_on_that_disagrees_with_started_at
    run = Jazari::Runs.open(target: queue, actor_ref: "a", now: Time.utc(2026, 8, 10, 12))[:run]
    assert_raises(ActiveRecord::StatementInvalid) do
      run.update_column(:started_on, Date.new(2026, 8, 11))
    end
  end

  def test_the_subject_pair_check_rejects_a_half_set_subject
    run = Jazari::Runs.open(target: queue, actor_ref: "a", now: Time.utc(2026, 8, 10, 12))[:run]
    assert_raises(ActiveRecord::StatementInvalid) do
      run.update_column(:subject_type, "DummySubject")   # id still NULL
    end
  end

  def test_an_unknown_run_policy_is_rejected_at_the_database
    assert_raises(ActiveRecord::StatementInvalid) do
      Jazari::RecipeRecord.connection.execute(
        "UPDATE jazari_recipes SET run_policy = 'whenever' WHERE recipe_id = 'daily.v1'"
      )
    end
  end

  def test_the_snapshot_column_is_not_nullable
    run = Jazari::Runs.open(target: queue, actor_ref: "a", now: Time.utc(2026, 8, 10, 12))[:run]
    assert_raises(ActiveRecord::NotNullViolation) do
      run.update_column(:checklist_snapshot, nil)
    end
  end

  # jsonb, not json: round-trip a tick and read it back as structured data.
  def test_jsonb_round_trips_tick_and_evidence_payloads
    run = Jazari::Runs.open(target: queue, actor_ref: "a", now: Time.utc(2026, 8, 10, 12))[:run]
    Jazari::Runs.tick(run: run, expected_revision: run.lock_version,
                      item_id: "a", done: true, actor_ref: "agent:1", note: "proved it")
    Jazari::Runs.attach_evidence(run: run.reload, expected_revision: run.lock_version,
                                 item_id: "a", kind: "count", value: "4211")

    reloaded = run.reload
    assert_equal "agent:1", reloaded.ticks.first["actor_ref"]
    assert_equal "proved it", reloaded.ticks.first["note"]
    assert_equal "4211", reloaded.evidence.first["value"]
    assert_equal "jsonb", Jazari::Run.columns_hash["ticks"].sql_type
  end
end
