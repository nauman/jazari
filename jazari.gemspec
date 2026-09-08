# frozen_string_literal: true

require_relative "lib/jazari/version"

Gem::Specification.new do |spec|
  spec.name        = "jazari"
  spec.version     = Jazari::VERSION
  # Required by RubyGems — a gemspec without authors will not even install from
  # git. The noreply address keeps a real inbox out of a public package while
  # still attributing the work.
  spec.authors     = [ "Nauman Tariq" ]
  spec.email       = [ "90499+nauman@users.noreply.github.com" ]
  spec.homepage    = "https://nauman.github.io/jazari/"
  spec.metadata    = {
    "homepage_uri"    => "https://nauman.github.io/jazari/",
    "source_code_uri" => "https://github.com/nauman/jazari",
    "changelog_uri"   => "https://github.com/nauman/jazari/blob/main/CHANGELOG.md"
  }

  spec.summary     = "Addressable operating procedures: recipes, runbooks, queues, and per-run evidence."
  spec.description = "A procedure you can call instead of a document you hope someone reads. " \
                     "Recipes as data, per-subject overrides, stable queue names for rituals that " \
                     "outlive any record, and per-run evidence so \"did last night's run complete?\" " \
                     "is a query."
  spec.license     = "MIT"
  spec.required_ruby_version = ">= 3.2"

  # IMPORTANT: an explicit allowlist, never `git ls-files` and never Dir["**/*"].
  # This is a shipping control, not a packaging detail — it is what keeps
  # everything outside these paths out of the published gem. Do not "tidy" it.
  spec.files = Dir[
    "lib/**/*.rb",
    "app/**/*.rb",
    "config/**/*.rb",
    "db/**/*.rb",
    "exe/*",
    "protocol/**/*.json",
    "README.md",
    "CHANGELOG.md",
    "LICENSE"
  ]

  spec.add_dependency "activerecord", ">= 7.1"
  spec.add_dependency "activesupport", ">= 7.1"
  # Temporary until https://github.com/rails/rails/issues/58685:
  # Active Support passes parser options positionally; JSON 3 accepts them as keywords.
  spec.add_dependency "json", "< 3"
  spec.add_dependency "sqlite3", ">= 2.1"

  spec.bindir = "exe"
  spec.executables = [ "jazari" ]
end
