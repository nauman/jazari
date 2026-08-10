# frozen_string_literal: true

require "rails/generators"
require "rails/generators/active_record"

module Jazari
  module Generators
    # Hosts adopt these tables DELIBERATELY. The gem never auto-appends its
    # migrations to a host's schema — a shared operations table appearing in
    # someone's next `db:migrate` without them asking for it is exactly the kind
    # of surprise that makes a gem untrustworthy in a production fleet.
    class InstallGenerator < ::Rails::Generators::Base
      include ::ActiveRecord::Generators::Migration

      source_root File.expand_path("templates", __dir__)

      desc "Copies the jazari migration into the host. PostgreSQL only."

      def copy_migration
        migration_template "create_jazari_tables.rb", "db/migrate/create_jazari_tables.rb"
      end

      def report
        say ""
        say "jazari: migration copied. Next:"
        say "  1. bin/rails db:migrate"
        say "  2. Seed your own recipes — the gem ships none by design."
        say "  3. Jazari.configure { |c| c.anchor_scopes = { ... } } at boot."
        say ""
        say "PostgreSQL is required: jsonb, timestamptz, CHECK constraints, and a"
        say "partial unique index over a COALESCEd polymorphic subject."
        say ""
      end
    end
  end
end
