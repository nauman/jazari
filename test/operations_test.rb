# frozen_string_literal: true

require_relative "test_helper"

class OperationsTest < Minitest::Test
  def setup
    Jazari::Run.delete_all
    Jazari::Runbook.delete_all
    Jazari::Anchor.delete_all
    Jazari::RecipeRecord.delete_all
    DummySubject.delete_all
    Jazari.configure { |c| c.anchor_scopes = { "Tree" => nil }; c.table_prefix = "jazari_" }

    Jazari::RecipeRegistry.seed!([
      { id: "canon.v1", topic: "How this operates", description: "## Purpose\n\nWhy.",
        checklist: [ { id: "seed-a", text: "First", done: false },
                     { id: "seed-b", text: "Second", done: false } ] }
    ])
    @subject = DummySubject.create!(name: "one")
  end

  def target = Jazari::RecordTarget.new(runbookable: @subject, public_reference: { kind: "dummy" }, recipe_id: "canon.v1")
  def queue  = Jazari::QueueTarget.new(queue: "ritual", public_reference: { kind: "queue" }, recipe_id: "canon.v1")
  def anchor_target
    Jazari::AnchorTarget.new(scope_type: "Tree", scope_id: 7, key: "node-x",
                             public_reference: { kind: "node" }, recipe_id: "canon.v1")
  end

  # --- resolving a default writes nothing -------------------------------

  def test_resolving_a_default_creates_no_rows
    resolved = Jazari::Operations.resolve(target: target)
    assert resolved.default?
    assert_equal "How this operates", resolved.topic
    assert_equal 0, Jazari::Runbook.count, "reading a default must not materialize a row"
    assert_equal 0, Jazari::Anchor.count, "reading a default must not create an anchor"
  end

  def test_default_revision_is_the_recipe_digest
    resolved = Jazari::Operations.resolve(target: target)
    assert_match(/\Adefault:[0-9a-f]{16}\z/, resolved.revision)
  end

  def test_progress_is_reported
    assert_equal({ done: 0, total: 2, percent: 0 }, Jazari::Operations.resolve(target: target).progress)
  end

  # --- customizing -------------------------------------------------------

  def test_first_customization_materializes_a_record
    resolved = Jazari::Operations.resolve(target: target)
    updated = Jazari::Operations.customize(
      target: target, expected_revision: resolved.revision,
      topic: "Our own words", description: "## Purpose\n\nOurs.",
      checklist: [ { id: "seed-a", text: "First", done: true } ]
    )
    assert updated.custom?
    assert_equal 0, updated.revision
    assert_equal 1, Jazari::Runbook.count
    assert_equal({ done: 1, total: 1, percent: 100 }, updated.progress)
  end

  def test_a_stale_default_revision_conflicts
    Jazari::Operations.resolve(target: target)
    assert_raises(Jazari::RevisionConflict) do
      Jazari::Operations.customize(target: target, expected_revision: "default:deadbeefdeadbeef",
                                   topic: "x", description: "", checklist: [])
    end
  end

  def test_editing_the_recipe_invalidates_an_outstanding_default_revision
    stale = Jazari::Operations.resolve(target: target).revision
    Jazari::RecipeRecord.find_by(recipe_id: "canon.v1").update!(topic: "Operator rewrote it")

    assert_raises(Jazari::RevisionConflict) do
      Jazari::Operations.customize(target: target, expected_revision: stale,
                                   topic: "x", description: "", checklist: [])
    end
  end

  def test_a_stale_custom_revision_conflicts
    r = Jazari::Operations.resolve(target: target)
    Jazari::Operations.customize(target: target, expected_revision: r.revision,
                                 topic: "t", description: "", checklist: [])
    assert_raises(Jazari::RevisionConflict) do
      Jazari::Operations.add_item(target: target, expected_revision: 99, text: "nope")
    end
  end

  # --- items -------------------------------------------------------------

  def test_add_check_and_remove_items_by_opaque_id
    r = Jazari::Operations.resolve(target: target)
    added = Jazari::Operations.add_item(target: target, expected_revision: r.revision, text: "Third")
    assert_equal 3, added.checklist.length

    new_id = added.checklist.last[:id]
    assert_match(/\A[A-Za-z0-9_-]{1,64}\z/, new_id)

    checked = Jazari::Operations.check_item(target: target, expected_revision: added.revision,
                                            item_id: new_id, done: true)
    assert checked.checklist.find { |i| i[:id] == new_id }[:done]

    removed = Jazari::Operations.remove_item(target: target, expected_revision: checked.revision, item_id: new_id)
    assert_equal 2, removed.checklist.length
  end

  def test_unknown_item_ids_are_rejected
    r = Jazari::Operations.resolve(target: target)
    custom = Jazari::Operations.customize(target: target, expected_revision: r.revision,
                                          topic: "t", description: "", checklist: [])
    assert_raises(Jazari::ItemNotFound) do
      Jazari::Operations.check_item(target: target, expected_revision: custom.revision,
                                    item_id: "ghost", done: true)
    end
  end

  def test_required_survives_a_round_trip
    r = Jazari::Operations.resolve(target: target)
    added = Jazari::Operations.add_item(target: target, expected_revision: r.revision,
                                        text: "Optional step", required: false)
    refute added.checklist.last[:required]
    assert_equal false, Jazari::Operations.resolve(target: target).checklist.last[:required]
  end

  # --- reset -------------------------------------------------------------

  def test_reset_destroys_the_customization_and_reveals_the_current_canon
    r = Jazari::Operations.resolve(target: target)
    custom = Jazari::Operations.customize(target: target, expected_revision: r.revision,
                                          topic: "Ours", description: "", checklist: [])
    Jazari::RecipeRecord.find_by(recipe_id: "canon.v1").update!(topic: "Corrected canon")

    back = Jazari::Operations.reset(target: target, expected_revision: custom.revision)
    assert back.default?
    assert_equal "Corrected canon", back.topic, "a reset subject must receive later recipe fixes"
    assert_equal 0, Jazari::Runbook.count
  end

  # --- queues are read-only ----------------------------------------------

  def test_a_queue_resolves_but_never_mutates
    resolved = Jazari::Operations.resolve(target: queue)
    assert resolved.default?
    assert_equal "How this operates", resolved.topic

    %i[customize add_item remove_item check_item reset].each do |op|
      assert_raises(Jazari::ReadOnlyTarget, "#{op} must refuse a queue") do
        case op
        when :customize then Jazari::Operations.customize(target: queue, expected_revision: resolved.revision, topic: "x", description: "", checklist: [])
        when :add_item then Jazari::Operations.add_item(target: queue, expected_revision: resolved.revision, text: "x")
        when :remove_item then Jazari::Operations.remove_item(target: queue, expected_revision: resolved.revision, item_id: "seed-a")
        when :check_item then Jazari::Operations.check_item(target: queue, expected_revision: resolved.revision, item_id: "seed-a", done: true)
        when :reset then Jazari::Operations.reset(target: queue, expected_revision: resolved.revision)
        end
      end
    end
    assert_equal 0, Jazari::Runbook.count
  end

  # --- anchors ------------------------------------------------------------

  def test_an_anchor_is_created_only_on_customization_and_destroyed_by_reset
    r = Jazari::Operations.resolve(target: anchor_target)
    assert_equal 0, Jazari::Anchor.count, "resolving must not create an anchor"

    custom = Jazari::Operations.customize(target: anchor_target, expected_revision: r.revision,
                                          topic: "Node truth", description: "", checklist: [])
    assert_equal 1, Jazari::Anchor.count
    assert_equal 1, Jazari::Runbook.count

    Jazari::Operations.reset(target: anchor_target, expected_revision: custom.revision)
    assert_equal 0, Jazari::Anchor.count, "reset must leave no orphan anchor"
    assert_equal 0, Jazari::Runbook.count
  end

  # --- last_run surfaces in resolve ---------------------------------------

  def test_resolve_reports_the_last_run
    assert_nil Jazari::Operations.resolve(target: queue).last_run

    run = Jazari::Runs.open(target: queue, actor_ref: "agent:1")[:run]
    Jazari::Runs.close(run: run, expected_revision: run.lock_version, outcome: "completed")

    summary = Jazari::Operations.resolve(target: queue).last_run
    assert_equal "completed", summary[:outcome]
    refute summary[:open]
  end

  # --- public API ----------------------------------------------------------

  def test_the_documented_runbook_api_is_callable
    r = Jazari.resolve(target: target)
    c = Jazari.customize(target: target, expected_revision: r.revision,
                         topic: "Via the public API", description: "", checklist: [])
    a = Jazari.add_item(target: target, expected_revision: c.revision, text: "step")
    k = Jazari.check_item(target: target, expected_revision: a.revision,
                          item_id: a.checklist.last[:id], done: true)
    d = Jazari.remove_item(target: target, expected_revision: k.revision,
                           item_id: k.checklist.last[:id])
    assert Jazari.reset(target: target, expected_revision: d.revision).default?
  end
end

class OperationsAnchorReadPathTest < Minitest::Test
  def setup
    Jazari::Run.delete_all
    Jazari::Runbook.delete_all
    Jazari::Anchor.delete_all
    Jazari::RecipeRecord.delete_all
    Jazari.configure { |c| c.anchor_scopes = { "Tree" => nil }; c.table_prefix = "jazari_" }
    Jazari::RecipeRegistry.seed!([ { id: "canon.v1", topic: "T",
      checklist: [ { id: "a", text: "A", done: false } ] } ])
  end

  def anchor_target
    Jazari::AnchorTarget.new(scope_type: "Tree", scope_id: 7, key: "never-made",
                             public_reference: {}, recipe_id: "canon.v1")
  end

  # Reading is not writing: an anchor that has never been customized has no
  # anchor row, and that is the normal state — not a failure.
  def test_resolving_an_uncreated_anchor_reads_the_default
    resolved = Jazari::Operations.resolve(target: anchor_target)
    assert resolved.default?
    assert_nil resolved.last_run
    assert_equal 0, Jazari::Anchor.count
  end

  # ...but it must not borrow another target's runs to answer last_run.
  def test_an_uncreated_anchor_never_reports_a_queue_run_as_its_own
    q = Jazari::QueueTarget.new(queue: "q", public_reference: {}, recipe_id: "canon.v1")
    Jazari::Runs.open(target: q, actor_ref: "a")
    assert_equal 1, Jazari::Run.count

    assert_nil Jazari::Operations.resolve(target: anchor_target).last_run,
      "a subject-less queue run must not surface as an anchor's last run"
  end

  # Opening a run is a write, and still fails closed.
  def test_opening_a_run_on_an_uncreated_anchor_still_fails_closed
    assert_raises(Jazari::TargetNotFound) do
      Jazari::Runs.open(target: anchor_target, actor_ref: "a")
    end
  end
end

class ForgetSubjectTest < Minitest::Test
  def setup
    Jazari::Run.delete_all
    Jazari::Runbook.delete_all
    Jazari::Anchor.delete_all
    Jazari::RecipeRecord.delete_all
    DummySubject.delete_all
    Jazari.configure { |c| c.anchor_scopes = { "Tree" => nil }; c.on_subject_destroyed = nil }
    Jazari::RecipeRegistry.seed!([ { id: "canon.v1", topic: "T",
      checklist: [ { id: "a", text: "A", done: false } ] } ])
    @subject = DummySubject.create!(name: "doomed")
  end

  def target
    Jazari::RecordTarget.new(runbookable: @subject, public_reference: {}, recipe_id: "canon.v1")
  end

  def test_forgetting_a_subject_removes_its_runbook
    r = Jazari::Operations.resolve(target: target)
    Jazari::Operations.customize(target: target, expected_revision: r.revision,
                                 topic: "Ours", description: "", checklist: [])
    assert_equal 1, Jazari::Runbook.count

    Jazari.forget_subject(@subject)
    assert_equal 0, Jazari::Runbook.count
  end

  # A run records something that actually happened. Deleting the subject does
  # not un-happen it, so the audit trail must survive.
  def test_runs_survive_the_subject_they_belonged_to
    run = Jazari::Runs.open(target: target, actor_ref: "a")[:run]
    Jazari::Runs.close(run: run, expected_revision: run.lock_version, outcome: "completed")

    Jazari.forget_subject(@subject)
    @subject.destroy!

    surviving = Jazari::Run.find_by(id: run.id)
    refute_nil surviving, "an audit record must outlive its subject"
    assert_equal "completed", surviving.outcome
    assert_equal "DummySubject", surviving.subject_type
  end

  def test_the_host_callback_is_invoked
    seen = []
    Jazari.configure { |c| c.on_subject_destroyed = ->(s) { seen << s } }
    Jazari.forget_subject(@subject)
    assert_equal [ @subject ], seen
  ensure
    Jazari.configure { |c| c.on_subject_destroyed = nil }
  end

  def test_forgetting_a_subject_with_no_runbook_is_a_no_op
    assert Jazari.forget_subject(@subject)
  end
end

class TableNameOverrideTest < Minitest::Test
  # A host adopting jazari onto tables it ALREADY has rarely finds that those
  # names follow one prefix — and renaming live tables in the same deploy as a
  # cut-over is precisely what an adoption plan forbids. So each table can be
  # named explicitly, with the prefix as the fallback.
  def test_individual_tables_can_be_named_explicitly
    original = Jazari.config.table_names
    Jazari.configure do |c|
      c.table_prefix = "legacy_"
      c.table_names = { anchors: "legacy_runbook_anchors", recipes: "legacy_runbook_recipes" }
    end

    assert_equal "legacy_runbook_anchors", Jazari::Anchor.table_name
    assert_equal "legacy_runbook_recipes", Jazari::RecipeRecord.table_name
    assert_equal "legacy_runbooks", Jazari::Runbook.table_name, "omitted keys fall back to the prefix"
    assert_equal "legacy_runs", Jazari::Run.table_name
  ensure
    Jazari.configure { |c| c.table_prefix = "jazari_"; c.table_names = original || {} }
    assert_equal "jazari_anchors", Jazari::Anchor.table_name
  end

  def test_an_unknown_table_key_raises_early
    assert_raises(KeyError) { Jazari.table_name_for(:nonsense) }
  end
end

class AnchorResolverContractTest < Minitest::Test
  # A host resolver must be told whether it may materialise the anchor.
  # Without that, resolving a DEFAULT would create a row — breaking the rule
  # that reading a default writes nothing at all.
  def setup
    Jazari::Run.delete_all
    Jazari::Runbook.delete_all
    Jazari::Anchor.delete_all
    Jazari::RecipeRecord.delete_all
    Jazari::RecipeRegistry.seed!([ { id: "canon.v1", topic: "T",
      checklist: [ { id: "a", text: "A", done: false } ] } ])
    @calls = []
    Jazari.configure do |c|
      c.anchor_scopes = { "Tree" => lambda do |target, create|
        @calls << create
        if create
          Jazari::Anchor.create_or_find_by!(scope_type: target.scope_type,
                                            scope_id: target.scope_id, key: target.key)
        else
          Jazari::Anchor.find_by(scope_type: target.scope_type,
                                 scope_id: target.scope_id, key: target.key)
        end
      end }
    end
  end

  def target
    Jazari::AnchorTarget.new(scope_type: "Tree", scope_id: 1, key: "n1",
                             public_reference: {}, recipe_id: "canon.v1")
  end

  def test_a_read_never_tells_the_resolver_it_may_create
    Jazari::Operations.resolve(target: target)

    # `resolve` asks twice — once to find a customization, once for last_run —
    # and both must be lookups. Asserting the COUNT would pin an internal
    # call pattern; what the contract actually promises is that no read ever
    # permits creation.
    refute_empty @calls
    assert(@calls.none?, "no read may permit the resolver to create")
    assert_equal 0, Jazari::Anchor.count, "reading a default must write nothing"
  end

  def test_a_write_tells_the_resolver_it_may_create
    r = Jazari::Operations.resolve(target: target)
    @calls.clear
    Jazari::Operations.customize(target: target, expected_revision: r.revision,
                                 topic: "Ours", description: "", checklist: [])
    assert_includes @calls, true, "customizing must permit creation"
    assert_equal 1, Jazari::Anchor.count
  end
end

class HostOwnedAnchorTest < Minitest::Test
  # A host may adopt jazari onto an anchor table it already owns, so the anchor
  # it returns is NOT a Jazari::Anchor. Nothing may depend on that class.
  class HostAnchor < ActiveRecord::Base
    self.table_name = "host_anchors"
    has_one :runbook, class_name: "Jazari::Runbook", as: :runbookable, dependent: :destroy
  end

  def setup
    ActiveRecord::Migration.suppress_messages do
      ActiveRecord::Schema.define do
        create_table :host_anchors, force: true do |t|
          t.string :key, null: false
          t.timestamps
        end
      end
    end
    Jazari::Runbook.delete_all
    Jazari::RecipeRecord.delete_all
    HostAnchor.delete_all
    Jazari::RecipeRegistry.seed!([ { id: "canon.v1", topic: "T",
      checklist: [ { id: "a", text: "A", done: false } ] } ])
    Jazari.configure do |c|
      c.anchor_scopes = { "HostTree" => lambda do |target, create|
        create ? HostAnchor.create_or_find_by!(key: target.key) : HostAnchor.find_by(key: target.key)
      end }
    end
  end

  def target
    Jazari::AnchorTarget.new(scope_type: "HostTree", scope_id: 1, key: "n1",
                             public_reference: {}, recipe_id: "canon.v1")
  end

  def test_reset_destroys_a_host_owned_anchor_leaving_no_orphan
    r = Jazari::Operations.resolve(target: target)
    custom = Jazari::Operations.customize(target: target, expected_revision: r.revision,
                                          topic: "Ours", description: "", checklist: [])
    assert_equal 1, HostAnchor.count
    assert_equal 1, Jazari::Runbook.count

    Jazari::Operations.reset(target: target, expected_revision: custom.revision)
    assert_equal 0, Jazari::Runbook.count
    assert_equal 0, HostAnchor.count, "reset must leave no orphan, even for a host-owned anchor"
  end
end

class LazyTableNameTest < Minitest::Test
  # Regression: table names were ASSIGNED at class-definition time, so the
  # binding depended on load order. Under Zeitwerk a host's `configure` runs
  # before these constants autoload, the assignment never happened, and the
  # models silently kept the gem's defaults — so a host that had adopted
  # existing tables queried tables that did not exist.
  def test_configuring_after_the_models_are_loaded_still_rebinds
    original = Jazari.config.table_names
    assert Jazari::RecipeRecord.table_name, "models are already loaded here"

    Jazari.configure { |c| c.table_names = { recipes: "late_bound_recipes" } }
    assert_equal "late_bound_recipes", Jazari::RecipeRecord.table_name,
      "a name set AFTER load must still take effect"
  ensure
    Jazari.configure { |c| c.table_names = original || {} }
  end

  def test_the_prefix_still_applies_to_unnamed_tables
    original = Jazari.config.table_names
    Jazari.configure { |c| c.table_prefix = "t_"; c.table_names = {} }
    assert_equal "t_runs", Jazari::Run.table_name
    assert_equal "t_anchors", Jazari::Anchor.table_name
  ensure
    Jazari.configure { |c| c.table_prefix = "jazari_"; c.table_names = original || {} }
    assert_equal "jazari_runs", Jazari::Run.table_name
  end
end
