# frozen_string_literal: true

require_relative "test_helper"
require "jazari/mcp/handler"
require "jazari/protocol/dispatcher"
require_relative "support/conformance_runner"

class ProtocolConformanceTest < Minitest::Test
  include Jazari::ConformanceRunner

  def setup
    Jazari.configure { |config| config.anchor_scopes = { "local" => nil } }
    reset_conformance_storage
  end

  def test_every_shared_conformance_fixture_passes_on_postgresql
    run_conformance_fixtures
  end

  def test_capabilities_report_the_active_backend
    request = {
      "protocol" => "jazari/v1", "request_id" => "capabilities",
      "action" => "capabilities", "arguments" => {}
    }
    response = conformance_dispatcher.call(request)

    assert_equal "postgresql", response.dig("result", "storage")
    validate_conformance_contract(request, response, __FILE__)
  end

  def test_dispatcher_does_not_register_or_replace_host_anchor_scopes
    resolver = ->(_target, _create) { nil }
    Jazari.configure { |config| config.anchor_scopes = { "Tree" => resolver } }
    Jazari::RecipeRegistry.seed!([ { id: "scope.v1", topic: "Scope", checklist: [] } ])

    response = conformance_dispatcher.call(
      "protocol" => "jazari/v1", "request_id" => "tree", "action" => "get",
      "target" => { "kind" => "anchor", "scope_type" => "Tree", "scope_id" => 1,
                    "key" => "node", "recipe_id" => "scope.v1" },
      "arguments" => {}
    )
    assert response["ok"]
    assert_same resolver, Jazari.config.anchor_scopes.fetch("Tree")

    response = conformance_dispatcher.call(
      "protocol" => "jazari/v1", "request_id" => "unknown", "action" => "get",
      "target" => { "kind" => "anchor", "scope_type" => "Unknown", "scope_id" => 1,
                    "key" => "node", "recipe_id" => "scope.v1" },
      "arguments" => {}
    )
    refute response["ok"]
    refute Jazari.config.anchor_scopes.key?("Unknown")
  end

  def test_request_schema_and_action_descriptors_require_the_same_fields
    document = JSON.parse(File.read(File.expand_path("../protocol/v1/request.schema.json", __dir__)))

    Jazari::Mcp::Actions::ALL.each do |action|
      branch = document.fetch("oneOf").find do |candidate|
        action_schema = candidate.dig("properties", "action") || {}
        action_schema["const"] == action.name || Array(action_schema["enum"]).include?(action.name)
      end
      refute_nil branch, "request schema has no #{action.name} branch"
      arguments = branch.dig("properties", "arguments")
      assert_equal action.required.map(&:to_s).sort, Array(arguments["required"]).sort, action.name
      assert_equal action.params.keys.map(&:to_s).sort,
        arguments.fetch("properties", {}).keys.sort, action.name
    end
  end

  private

  def reset_conformance_storage
    Jazari::Run.delete_all
    Jazari::Runbook.delete_all
    Jazari::Anchor.delete_all
    Jazari::RecipeRecord.delete_all
    @conformance_dispatcher = Jazari::Protocol::Dispatcher.new
  end

  attr_reader :conformance_dispatcher
end
