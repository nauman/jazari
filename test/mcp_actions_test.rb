# frozen_string_literal: true

require_relative "test_helper"

# These prove the DSL a host absorbs into its OWN tool. If a host builds its
# schema from these and dispatches itself, nothing here may drift from what
# the domain actually accepts.
class McpActionsTest < Minitest::Test
  def test_every_action_is_declared_once_with_a_summary
    names = Jazari::Mcp::Actions::NAMES
    assert_equal names.uniq, names, "an action declared twice would produce a duplicate enum entry"
    Jazari::Mcp::Actions::ALL.each do |action|
      refute_empty action.summary, "#{action.name} has no summary — a host would publish a blank description"
      assert_includes %i[read additive overwrite destructive], action.effect
      assert_includes %i[read write], action.scope
    end
  end

  def test_read_scope_advertises_no_writes
    read = Jazari::Mcp::Actions.all(scope: :read)
    assert_equal %w[get last_run], read.map(&:name)
    assert(read.all?(&:read?))
  end

  def test_the_schema_fragment_is_mergeable_into_a_host_tool
    frag = Jazari::Mcp::Actions.schema_fragment

    assert_includes frag[:enum], "start"
    assert_includes frag[:properties].keys, :expected_revision
    assert_equal "string", frag[:properties][:expected_revision][:type]

    # A host merges these into its own tool without adopting our handler.
    host_tool = { properties: { action: { enum: %w[my_existing_action] } } }
    host_tool[:properties][:action][:enum] += frag[:enum]
    host_tool[:properties].merge!(frag[:properties])

    assert_includes host_tool[:properties][:action][:enum], "my_existing_action"
    assert_includes host_tool[:properties][:action][:enum], "tick"
  end

  def test_a_read_scoped_fragment_carries_no_write_parameters
    frag = Jazari::Mcp::Actions.schema_fragment(scope: :read)
    assert_equal %w[get last_run], frag[:enum]
    refute_includes frag[:properties].keys, :expected_revision,
      "a read-only tool must not advertise a mutation parameter"
  end

  def test_destructive_and_confirm_gated_actions_are_flagged_for_hosts
    assert_equal :destructive, Jazari::Mcp::Actions.fetch("reset").effect
    assert Jazari::Mcp::Actions.fetch("reset").confirm?, "reset discards operator content"
    assert_equal :destructive, Jazari::Mcp::Actions.fetch("remove_item").effect
    assert_equal :overwrite, Jazari::Mcp::Actions.fetch("set").effect
    refute Jazari::Mcp::Actions.fetch("get").confirm?
  end

  def test_an_unknown_action_raises
    assert_raises(ArgumentError) { Jazari::Mcp::Actions.fetch("drop_everything") }
  end

  # The descriptors and the shipped handler must not drift.
  def test_the_handler_dispatches_exactly_the_declared_actions
    require "jazari/mcp/handler"
    Jazari::Mcp::Actions::NAMES.each do |name|
      assert Jazari::Mcp::Handler.new.respond_to?(:"handle_#{name}"),
        "#{name} is declared but the handler cannot dispatch it"
    end
    assert_equal Jazari::Mcp::Actions::NAMES, Jazari::Mcp::Handler.actions_for(:write)
  end

  # The MCP layer is optional: descriptors load, the dispatcher does not.
  #
  # Checked in a CLEAN SUBPROCESS on purpose. A sibling test in this file
  # requires the handler, so an in-process $LOADED_FEATURES check would pass or
  # fail depending on test order — proving nothing.
  def test_only_the_descriptors_load_by_default
    script = <<~RUBY
      require "jazari"
      puts $LOADED_FEATURES.grep(%r{jazari/mcp/actions}).any?
      puts $LOADED_FEATURES.grep(%r{jazari/mcp/handler}).any?
    RUBY
    out = IO.popen([ "ruby", "-I", "lib", "-e", script ], &:read)
    actions_loaded, handler_loaded = out.split("\n")

    assert_equal "true", actions_loaded, "descriptors are cheap and always available"
    assert_equal "false", handler_loaded, "the dispatcher must stay opt-in"
  end

  # ...and requiring it explicitly must work on its own, without `jazari` having
  # pulled Actions in first.
  def test_the_handler_can_be_required_standalone
    script = <<~RUBY
      require "jazari/mcp/handler"
      puts Jazari::Mcp::Handler.actions_for(:read).inspect
    RUBY
    out = IO.popen([ "ruby", "-I", "lib", "-e", script ], &:read)
    assert_includes out, "get", "requiring the handler alone must not NameError"
  end
end
