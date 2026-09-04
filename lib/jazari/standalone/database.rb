# frozen_string_literal: true

module Jazari
  module Standalone
    module Database
      TABLES = Jazari::TABLES.keys.freeze
      BUSY_TIMEOUT = 5_000

      module_function

      def connect!(path)
        raise ArgumentError, "database path is required" if path.to_s.empty?
        raise ArgumentError, "standalone storage requires a SQLite file, not :memory:" if path.to_s == ":memory:"

        configure_local_anchors!
        path = File.expand_path(path.to_s)

        FileUtils.mkdir_p(File.dirname(path))
        ActiveRecord::Base.establish_connection(
          adapter: "sqlite3", database: path, timeout: BUSY_TIMEOUT, pool: 5
        )
        connection = Jazari::ApplicationRecord.connection
        connection.execute("PRAGMA foreign_keys = ON")
        connection.execute("PRAGMA journal_mode = WAL")
        connection.execute("PRAGMA busy_timeout = #{BUSY_TIMEOUT}")
        migrate!(connection)
        connection
      end

      def migrate!(connection, migration: CreateJazariTables.new)
        connection.raw_connection.transaction(:immediate) do
          existing = TABLES.select { |key| connection.data_source_exists?(Jazari.table_name_for(key)) }
          next if existing.length == TABLES.length

          if existing.any?
            raise "partial Jazari schema: found #{existing.join(', ')}; refusing an implicit repair"
          end

          ActiveRecord::Migration.suppress_messages do
            migration.migrate(:up)
          end
        end
      end

      def configure_local_anchors!
        Jazari.configure do |config|
          config.table_prefix = "jazari_"
          config.table_names = {}
          config.anchor_scopes = { "local" => nil }
        end
      end
    end
  end
end
