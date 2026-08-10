# frozen_string_literal: true

require "bundler/gem_tasks"   # build / install / release
require "rake/testtask"

Rake::TestTask.new(:test) do |t|
  t.libs << "lib" << "test"
  t.test_files = FileList["test/**/*_test.rb"]
  t.warning = false
end

# ── the boundary check ────────────────────────────────────────────────────
#
# This gem is publishable only because it is product-agnostic — the same
# property that made extracting it worth doing. Two assertions enforce that:
#
#   1. Every library file lives inside `module Jazari`. A file that does not is
#      declaring something in the host's global namespace.
#   2. The test suite names no subject beyond the gem and one dummy. Tests are
#      where coupling to a real host model would first appear, because that is
#      where subjects get instantiated.
#
# Deliberately an ALLOWLIST, not a list of forbidden product names: a denylist
# would have to enumerate the private systems it protects — publishing, in a
# public repo, exactly what it exists to conceal — and would only ever catch
# names someone remembered to add.
# DummySubject and HostAnchor are the suite's ONLY stand-ins for a host: one
# for an ordinary subject, one for a host-owned anchor class. Adding a third
# should require a reason — each is a place a real application model could
# creep in.
TEST_ALLOWED = %w[
  Jazari DummySubject HostAnchor
  ActiveRecord Minitest
  Time Date Object ENV DB
  ArgumentError StandardError RuntimeError NameError NoMethodError TypeError KeyError
  String Symbol Integer Float Array Hash Struct Data Range Set
].freeze

desc "Fail if the gem or its suite couples to anything outside its own namespace"
task :boundary do
  problems = []

  Dir["lib/**/*.rb", "app/**/*.rb"].each do |file|
    next if file.include?("generators/") # migration templates are host-facing by design
    problems << "#{file}: no `module Jazari`" unless File.read(file).include?("module Jazari")
  end

  Dir["test/**/*.rb"].each do |file|
    File.readlines(file).each_with_index do |raw, i|
      next if raw.strip.start_with?("#")

      # Strip string literals and symbols first: a capitalised WORD inside
      # "Daily ritual" is data, not a constant reference. Without this the
      # check reports the suite's own fixture text as a boundary breach.
      line = raw.gsub(/"[^"]*"/, '""').gsub(/'[^']*'/, "''")
                .gsub(%r{/(?:[^/\\]|\\.)*/}, "//")   # regex literals: /\A[A-Za-z0-9]/ is not a constant
                .gsub(/:[a-z_]+/, "")

      # Match a WHOLE constant path and judge only its root: `Foo::Bar::Baz`
      # is a reference to `Foo`. The lookbehind stops us matching `Bar` and
      # `Baz` as separate roots.
      line.scan(/(?<![:\w])([A-Z][A-Za-z0-9]*(?:::[A-Z][A-Za-z0-9]*)*)/).flatten.uniq.each do |path|
        root = path.split("::").first
        next if TEST_ALLOWED.include?(root)
        next if root == root.upcase          # SCREAMING_CASE locals
        next if root.start_with?("Create")   # the shipped migration class
        next if root.end_with?("Test")       # the suite's own test-case classes

        problems << "#{file}:#{i + 1} names `#{path}` — outside the gem's namespace"
      end
    end
  end

  if problems.any?
    problems.uniq.each { |p| warn "  #{p}" }
    abort "BOUNDARY FAILED — see above."
  end
  puts "boundary: clean — the gem and its suite name nothing outside their own namespace"
end

desc "Fail if a GitHub workflow file is not valid YAML"
task :workflows do
  require "yaml"
  Dir[".github/workflows/*.yml"].each do |file|
    YAML.load_file(file)
    puts "workflow ok: #{file}"
  rescue => error
    abort "INVALID WORKFLOW #{file}: #{error.message}"
  end
end

# `workflows` is in the gate because a broken workflow fails at 0s with no test
# output — the local hook runs the suite, so it cannot catch a CI file that
# never starts. Cheap check, whole class of failure.
task default: %i[boundary workflows test]
