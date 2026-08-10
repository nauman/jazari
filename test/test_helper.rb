# frozen_string_literal: true

require "minitest/autorun"
require "active_record"
require "jazari"
require_relative "../app/models/jazari/application_record"
require_relative "../app/models/jazari/recipe_record"
require_relative "../app/models/jazari/runbook"
require_relative "../app/models/jazari/anchor"
require_relative "../app/models/jazari/run"

# PostgreSQL only. The gem's guarantees lean on Postgres semantics: jsonb,
# timestamptz, CHECK constraints, and a partial unique index over a COALESCEd
# polymorphic subject. Testing against anything else would prove a schema we do
# not ship. Other adapters can be added later if someone asks for one.
DB = ENV.fetch("JAZARI_TEST_DATABASE", "jazari_test")

ActiveRecord::Base.establish_connection(adapter: "postgresql", database: "postgres",
                                        schema_search_path: "public")
begin
  ActiveRecord::Base.connection.create_database(DB)
rescue ActiveRecord::DatabaseAlreadyExists
  nil
end
ActiveRecord::Base.establish_connection(adapter: "postgresql", database: DB)
ActiveRecord::Base.logger = nil

# A DUMMY host subject. The gem's suite must never name a real host model — if
# it does, the architecture boundary leaked and so did the IP.
class DummySubject < ActiveRecord::Base; end

# THE POINT: the tests run the migration the gem actually ships. There is no
# second hand-maintained schema to drift away from it, so a CHECK constraint or
# column type that exists in the template is exercised here by construction.
require_relative "../lib/generators/jazari/install/templates/create_jazari_tables"

ActiveRecord::Migration.suppress_messages do
  ActiveRecord::Schema.define do
    drop_table :jazari_runs, if_exists: true
    drop_table :jazari_runbooks, if_exists: true
    drop_table :jazari_anchors, if_exists: true
    drop_table :jazari_recipes, if_exists: true
    drop_table :dummy_subjects, if_exists: true

    create_table :dummy_subjects do |t|
      t.string :name
    end
  end

  CreateJazariTables.new.migrate(:up)
end
