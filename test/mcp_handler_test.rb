# frozen_string_literal: true

require_relative "test_helper"
require "jazari/mcp/handler"   # optional layer — hosts opt in

# The handler is what every host's tool calls. These prove the wire shape a
# host can rely on, and that domain errors cross it as codes rather than
# messages that could disclose a record or whether a target exists.
class McpHandlerTest < Minitest::Test
  def setup
    Jazari::Run.delete_all
    Jazari::Runbook.delete_all
    Jazari::RecipeRecord.delete_all
    DummySubject.delete_all
    Jazari.configure { |c| c.table_prefix = "jazari_"; c.anchor_scopes = {} }
    Jazari::RecipeRegistry.seed!([
      { id: "canon.v1", topic: "How it operates", description: "## Purpose\n\nWhy.",
        checklist: [ { id: "a", text: "First", done: false } ] }
    ])
    @handler = Jazari::Mcp::Handler.new
    @subject = DummySubject.create!(name: "one")
    Jazari.configure { |c| c.actor_ref = nil }
  end

  def target = Jazari::RecordTarget.new(runbookable: @subject, public_reference: { kind: "dummy" }, recipe_id: "canon.v1")
  def queue  = Jazari::QueueTarget.new(queue: "ritual", public_reference: { kind: "queue" }, recipe_id: "canon.v1")

  def test_get_returns_the_resolved_document
    reply = @handler.call(action: "get", target: target)
    assert reply[:ok]
    assert_equal "default", reply[:state]
    assert_equal "How it operates", reply[:topic]
    assert_equal({ done: 0, total: 1, percent: 0 }, reply[:progress])
    assert_match(/\Adefault:/, reply[:revision])
    assert_equal({ kind: "dummy" }, reply[:target_reference])
  end

  def test_recipe_provenance_never_leaks_an_implementation_class
    recipe = @handler.call(action: "get", target: target)[:recipe]
    assert_equal %i[id version digest], recipe.keys
    refute_match(/Jazari|Record|Class/, recipe[:id])
  end

  def test_domain_errors_cross_the_wire_as_codes_only
    reply = @handler.call(action: "set", target: target, arguments: {
      expected_revision: "default:wrong", topic: "x", description: "", checklist: []
    })
    refute reply[:ok]
    assert_equal "revision_conflict", reply[:error]
    assert_nil reply[:message], "a message could disclose a record or a query"
  end

  def test_a_queue_refuses_mutation_with_a_code
    reply = @handler.call(action: "add_item", target: queue,
                          arguments: { expected_revision: "x", text: "nope" })
    assert_equal "read_only_target", reply[:error]
  end

  def test_reset_requires_explicit_confirmation
    reply = @handler.call(action: "reset", target: target, arguments: { expected_revision: "x" })
    assert_equal "invalid_runbook", reply[:error]
  end

  def test_unknown_actions_are_rejected
    assert_raises(ArgumentError) { @handler.call(action: "drop_everything", target: target) }
  end

  def test_read_scope_advertises_no_mutations
    assert_equal %w[get last_run], Jazari::Mcp::Handler.actions_for("read")
    assert_includes Jazari::Mcp::Handler.actions_for("write"), "set"
  end

  def test_the_full_run_lifecycle_over_the_wire
    started = @handler.call(action: "start", target: queue, arguments: { actor_ref: "agent:1" })
    assert started[:ok]
    assert started[:created]
    assert started[:open]

    ticked = @handler.call(action: "tick", target: queue, arguments: {
      run_id: started[:run_id], expected_revision: started[:revision],
      item_id: "a", done: true, actor_ref: "agent:1", note: "proved it"
    })
    assert_equal 1, ticked[:ticks].length

    evidenced = @handler.call(action: "evidence", target: queue, arguments: {
      run_id: ticked[:run_id], expected_revision: ticked[:revision],
      item_id: "a", kind: "count", value: "4211", actor_ref: "agent:1"
    })
    assert_equal "4211", evidenced[:evidence].first["value"]
    assert_equal "agent:1", evidenced[:evidence].first["actor_ref"]

    finished = @handler.call(action: "finish", target: queue, arguments: {
      run_id: evidenced[:run_id], expected_revision: evidenced[:revision], outcome: "completed"
    })
    refute finished[:open]

    assert_equal "completed", @handler.call(action: "last_run", target: queue)[:outcome]
  end

  def test_last_run_is_nil_before_any_run
    assert_nil @handler.call(action: "last_run", target: queue)[:last_run]
  end

  def test_get_surfaces_the_last_run_so_one_read_answers_did_it_complete
    started = @handler.call(action: "start", target: queue, arguments: { actor_ref: "a" })
    @handler.call(action: "finish", target: queue,
                  arguments: { run_id: started[:run_id], expected_revision: started[:revision],
                               outcome: "completed" })
    assert_equal "completed", @handler.call(action: "get", target: queue)[:last_run][:outcome]
  end
end
