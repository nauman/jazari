# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Jazari
  module Generators
    # For hosts that already installed the tables. Schema changes are copied,
    # never applied on the gem's own initiative, for the same reason install is
    # explicit: a shared operations table changing shape inside someone else's
    # `db:migrate` is not a change they agreed to.
    class UpgradeGenerator < ::Rails::Generators::Base
      include ::ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Copies the schema changes an already-installed host needs. PostgreSQL only."

      def copy_migration
        migration_template "add_jazari_runbook_origin.rb", "db/migrate/add_jazari_runbook_origin.rb"
      end

      def report
        say ""
        say "jazari: upgrade migration copied. It is additive and nullable, so it"
        say "is safe to run ahead of the code that writes the column."
        say ""
      end
    end
  end
end
