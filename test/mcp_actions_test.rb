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
    assert_equal "string", frag[:properties][:actor_ref][:type]

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

  # --- descriptor -> served schema -> domain ----------------------------
  #
  # The defect this pins: `checklist` was published as a bare `array` with no
  # `items`. A client generating from that descriptor inferred `string[]`, sent
  # ["step one"], and the domain rejected it with "checklist item must be a
  # hash". The schema and the validator disagreed, and only the client found out.
  #
  # So the assertion is EQUIVALENCE, not a happy path: for each payload, what
  # the published schema admits and what the domain admits must agree. A test
  # that hand-builds one valid item from the schema proves only that someone
  # picked a good example.

  # A deliberately small JSON Schema evaluator covering exactly the keywords
  # these descriptors use.
  #
  # It RAISES on a keyword it does not implement. A silent skip would make the
  # containment test pass by ignoring the very constraint someone just added,
  # which is how a contract test becomes decoration.
  KEYWORDS = %i[type description items properties required additionalProperties
                minLength maxLength pattern maxItems].freeze

  def schema_admits?(schema, value)
    unknown = schema.keys.map(&:to_sym) - KEYWORDS
    raise "schema_admits? does not implement #{unknown.join(', ')} — teach it before trusting it" if unknown.any?

    # Real JSON arrives with string keys. Comparing a symbol-keyed schema
    # against a string-keyed instance would reject every genuine payload as an
    # additional property, and the containment assertion would pass vacuously.
    schema = schema.transform_keys(&:to_sym)

    case schema[:type]
    when "array"
      return false unless value.is_a?(Array)
      return false if schema[:maxItems] && value.length > schema[:maxItems]

      value.all? { |element| schema_admits?(schema[:items], element) }
    when "object"
      return false unless value.is_a?(Hash)

      value = value.transform_keys(&:to_sym)
      props = schema[:properties].transform_keys(&:to_sym)
      return false if schema[:additionalProperties] == false && (value.keys - props.keys).any?
      return false unless Array(schema[:required]).all? { |key| value.key?(key.to_sym) }

      value.all? { |key, element| props[key] && schema_admits?(props[key], element) }
    when "string"
      return false unless value.is_a?(String)
      return false if schema[:minLength] && value.length < schema[:minLength]
      return false if schema[:maxLength] && value.length > schema[:maxLength]
      return false if schema[:pattern] && !Regexp.new(schema[:pattern]).match?(value)

      true
    when "boolean" then [ true, false ].include?(value)
    else false
    end
  end

  def domain_admits?(payload)
    Jazari::Checklist.normalize(payload)
    true
  rescue Jazari::InvalidRunbook
    false
  end

  # The contract is CONTAINMENT, not equality: everything the schema admits, the
  # domain must admit. That is the direction that hurts — a client generating a
  # payload from the published schema and being rejected at call time is exactly
  # the incident. The reverse (domain laxer than schema) costs a caller nothing,
  # and is pinned separately below so it stays deliberate.
  def test_no_payload_the_schema_admits_is_rejected_by_the_domain
    checklist = Jazari::Mcp::Actions.schema_fragment(scope: :write)[:properties][:checklist]

    cases = {
      "a minimal item" => [ { text: "Do it" } ],
      "a full item" => [ { id: "step-a", text: "Do it", done: true, required: false } ],
      "a bare string — the shape that caused the incident" => [ "step one" ],
      "empty text" => [ { text: "" } ],
      "text one over MAX_TEXT" => [ { text: "x" * (Jazari::Checklist::MAX_TEXT + 1) } ],
      "text exactly at MAX_TEXT" => [ { text: "x" * Jazari::Checklist::MAX_TEXT } ],
      "an unknown key" => [ { text: "Do it", note: "extra" } ],
      "a missing text" => [ { id: "step-a", done: false } ],
      "201 small items — no row cap in either" => Array.new(201) { { text: "Do it" } },
      # The shape that actually arrives over the wire.
      "a string-keyed item, as JSON delivers it" => [ { "text" => "Do it", "done" => false } ]
    }

    cases.each do |label, payload|
      next unless schema_admits?(checklist, payload)

      assert domain_admits?(payload),
        "the schema admits #{label} and the domain rejects it — that is the defect"
    end

    # ...and the schema must not be so loose that it admits nothing useful, nor
    # so tight that it rejects what the domain takes happily.
    cases.each do |label, payload|
      next unless domain_admits?(payload)
      next if payload.any? { |item| item.is_a?(Hash) && !item[:done].nil? && ![ true, false ].include?(item[:done]) }

      assert schema_admits?(checklist, payload),
        "the domain accepts #{label} but the schema does not describe it"
    end
  end

  # The one place the schema is deliberately STRICTER than the domain.
  #
  # `done: "yes"` is accepted and silently coerced to false, because the domain
  # reads `done == true`. Publishing `boolean` stops a client sending it and
  # believing they ticked the step. Strict-schema/lax-domain is the safe
  # direction — the caller is told up front instead of misled afterwards — but
  # it is worth pinning so nobody "fixes" the schema to match the coercion.
  def test_the_schema_refuses_a_truthy_string_the_domain_would_silently_coerce
    checklist = Jazari::Mcp::Actions.schema_fragment(scope: :write)[:properties][:checklist]
    payload = [ { text: "Do it", done: "yes" } ]

    refute schema_admits?(checklist, payload)
    assert domain_admits?(payload)
    assert_equal false, Jazari::Checklist.normalize(payload).first[:done],
      "the coercion this schema protects the caller from"
  end

  # The one rule JSON Schema cannot express. If it cannot be enforced by the
  # schema it must at least be disclosed by it, or the client learns the limit
  # by being rejected — the same failure as an untyped array.
  def test_the_aggregate_byte_bound_is_disclosed_since_it_cannot_be_expressed
    checklist = Jazari::Mcp::Actions.schema_fragment(scope: :write)[:properties][:checklist]

    assert_match(/#{Jazari::Checklist::MAX_PAYLOAD}/, checklist[:description])

    over = Array.new(200) { |i| { id: "step-#{i}", text: "x" * Jazari::Checklist::MAX_TEXT } }
    assert schema_admits?(checklist, over), "the schema cannot express the aggregate bound"
    refute domain_admits?(over), "...which is exactly why it has to be written down"
  end


  # A pattern is only a contract if the client's validator can read it. Ruby's
  # \A/\z do not exist in ECMAScript, which is what JSON Schema specifies.
  def test_the_published_id_pattern_is_ecmascript_not_ruby
    pattern = Jazari::Mcp::Actions.schema_fragment(scope: :write)[:properties][:checklist][:items][:properties][:id][:pattern]

    refute_includes pattern, "\\A", "a Ruby-only anchor in a published JSON Schema pattern"
    refute_includes pattern, "\\z"

    # Compile it the way ECMAScript reads it, not the way Ruby does.
    #
    # Ruby's `$` matches before a trailing newline; ECMAScript's `$` without the
    # `m` flag does not. Compiling the published pattern with a bare Regexp.new
    # would have made "abc\n" look accepted here while a real JSON Schema
    # validator correctly rejects it — the test would have proved nothing about
    # the consumer it exists to protect. Verified against node: both false.
    compiled = Regexp.new(pattern.sub(/\A\^/, '\\A').sub(/\$\z/, '\\z'))

    # Derived, not hand-copied: it must accept and reject exactly what the
    # domain's own ID_FORMAT does.
    [ "step-a", "a" * 64, "A_b-1" ].each do |id|
      assert compiled.match?(id), "#{id} is a valid jazari id"
      assert Jazari::Checklist::ID_FORMAT.match?(id)
    end
    [ "a" * 65, "has space", "", "abc\n", "bad\nstep-a" ].each do |id|
      refute compiled.match?(id), "#{id} is not a valid jazari id"
      refute Jazari::Checklist::ID_FORMAT.match?(id)
    end
  end

end
