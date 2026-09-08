# frozen_string_literal: true

require "minitest/autorun"
require "active_support/json"

class GemspecTest < Minitest::Test
  def test_runtime_json_dependency_stays_compatible_with_active_support
    specification = Gem::Specification.load(File.expand_path("../jazari.gemspec", __dir__))
    dependency = specification.runtime_dependencies.find { |candidate| candidate.name == "json" }

    refute_nil dependency, "Jazari requires JSON directly and must declare its compatibility boundary"
    assert dependency.requirement.satisfied_by?(Gem::Version.new("2.21.2"))
    refute dependency.requirement.satisfied_by?(Gem::Version.new("3.0.0"))
  end

  def test_active_support_can_decode_json_with_the_resolved_parser
    assert_equal({ "ok" => true }, ActiveSupport::JSON.decode('{"ok":true}'))
  end
end
