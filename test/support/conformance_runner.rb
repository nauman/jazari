# frozen_string_literal: true

require "json_schemer"
require "pathname"
require "uri"

module Jazari::ConformanceRunner
    FIXTURES = File.expand_path("../../protocol/v1/fixtures/*/scenario.json", __dir__)

    def run_conformance_fixtures
      Dir.glob(FIXTURES).sort.each { |path| run_conformance_fixture(path) }
    end

    private

    def run_conformance_fixture(path)
      reset_conformance_storage
      fixture = JSON.parse(File.read(path))
      Jazari::RecipeRegistry.seed!(fixture.fetch("recipes", []))
      responses = []

      fixture.fetch("steps").each do |step|
        if step["setup"]
          apply_conformance_setup(step.fetch("setup"))
          next
        end

        request = resolve_conformance_references(step.fetch("request"), responses)
        response = conformance_dispatcher.call(request)
        validate_conformance_contract(request, response, path)
        assert_conformance_subset(step.fetch("expect"), response, fixture_name(path))
        Array(step["equal"]).each do |actual_path, prior_index, prior_path|
          assert_equal dig_conformance_path(responses.fetch(prior_index), prior_path),
            dig_conformance_path(response, actual_path)
        end
        responses << response
      end
    end

    def apply_conformance_setup(setup)
      if setup["seed"]
        Jazari::RecipeRegistry.seed!(setup.fetch("seed"))
      elsif setup["replace_recipe"]
        replace_conformance_recipe(setup.fetch("replace_recipe"))
      else
        flunk "unknown fixture setup #{setup.keys.join(', ')}"
      end
    end

    def replace_conformance_recipe(entry)
      record = Jazari::RecipeRecord.find_by!(recipe_id: entry.fetch("id"))
      record.update!(
        topic: entry.fetch("topic"), description: entry.fetch("description", ""),
        checklist: Jazari::Checklist.normalize(entry.fetch("checklist", [])).map { |item| item.transform_keys(&:to_s) }
      )
    end

    def resolve_conformance_references(value, responses)
      case value
      when Hash
        value.to_h { |key, nested| [ key, resolve_conformance_references(nested, responses) ] }
      when Array
        value.map { |nested| resolve_conformance_references(nested, responses) }
      when String
        match = value.match(/\A\$(\d+)\.(.+)\z/)
        match ? dig_conformance_path(responses.fetch(match[1].to_i), match[2]) : value
      else value
      end
    end

    def validate_conformance_contract(request, response, path)
      request_schema, response_schema = conformance_schemers
      assert_empty request_schema.validate(request).to_a, "#{fixture_name(path)} request schema"
      assert_empty response_schema.validate(response).to_a, "#{fixture_name(path)} response schema"
    end

    def conformance_schemers
      @conformance_schemers ||= begin
        root = Pathname.new(File.expand_path("../..", __dir__))
        documents = Dir[root.join("protocol/v1/*.schema.json")].to_h do |schema_path|
          document = JSON.parse(File.read(schema_path))
          [ URI(document.fetch("$id")), document ]
        end
        resolver = documents.to_proc
        %w[request response].map do |name|
          document = documents.fetch(URI("https://github.com/nauman/jazari/protocol/v1/#{name}.schema.json"))
          JSONSchemer.schema(document, ref_resolver: resolver)
        end
      end
    end

    def dig_conformance_path(value, path)
      path.split(".").reduce(value) { |memo, key| memo.fetch(key) }
    end

    def assert_conformance_subset(expected, actual, label)
      case expected
      when Hash
        expected.each do |key, value|
          assert actual.key?(key), "#{label}: missing #{key} in #{actual.inspect}"
          assert_conformance_subset(value, actual.fetch(key), label)
        end
      when Array
        assert_operator actual.length, :>=, expected.length, "#{label}: array is shorter than expected"
        expected.each_with_index { |value, index| assert_conformance_subset(value, actual.fetch(index), label) }
      else
        assert_equal expected, actual, label
      end
    end

    def fixture_name(path) = File.basename(File.dirname(path))
end
