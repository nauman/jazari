# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require "stringio"
require "open3"
require "jazari/standalone"
require_relative "support/conformance_runner"

class StandaloneSqliteTest < Minitest::Test
  include Jazari::ConformanceRunner

  def setup
    @tmp = Dir.mktmpdir("jazari-standalone")
    @database = File.join(@tmp, "jazari.sqlite3")
    @app = Jazari::Standalone::App.new(database: @database)
  end

  def teardown
    ActiveRecord::Base.connection_pool.disconnect!
    FileUtils.remove_entry(@tmp)
  end

  def test_sqlite_uses_foreign_keys_wal_and_the_utc_date_constraint
    connection = ActiveRecord::Base.connection
    assert_equal 1, connection.select_value("PRAGMA foreign_keys")
    assert_equal "wal", connection.select_value("PRAGMA journal_mode")

    assert_raises(ActiveRecord::StatementInvalid) do
      Jazari::Run.create!(
        recipe_id: "x", source_digest: "x", actor_ref: "actor", started_at: Time.utc(2026, 1, 2),
        started_on: Date.new(2026, 1, 1), idempotency_policy: "unrestricted",
        checklist_snapshot: [], ticks: [], evidence: []
      )
    end
  end

  def test_partial_schema_is_refused_instead_of_silently_repaired
    ActiveRecord::Base.connection.drop_table(:jazari_runs)
    error = assert_raises(RuntimeError) do
      Jazari::Standalone::Database.migrate!(ActiveRecord::Base.connection)
    end
    assert_match(/partial Jazari schema/, error.message)
  end

  def test_failed_first_migration_rolls_back_every_table
    connection = ActiveRecord::Base.connection
    Jazari::Standalone::Database::TABLES.reverse_each do |key|
      connection.drop_table(Jazari.table_name_for(key), if_exists: true)
    end
    failing_migration = Class.new(ActiveRecord::Migration[7.1]) do
      def change
        create_table(:jazari_recipes) { |table| table.string :recipe_id }
        raise "interrupted"
      end
    end.new

    assert_raises(RuntimeError) do
      Jazari::Standalone::Database.migrate!(connection, migration: failing_migration)
    end
    refute connection.data_source_exists?(:jazari_recipes)
  end

  def test_protocol_rejects_unknown_fields_and_never_dispatches_them
    response = @app.call(
      protocol: "jazari/v1", request_id: "bad", action: "capabilities",
      arguments: {}, surprise: true
    )
    refute response["ok"]
    assert_equal "invalid_request", response.dig("error", "code")

    response = @app.call(
      protocol: "jazari/v1", request_id: "bad-value", action: "start",
      target: { kind: "queue", key: "queue", recipe_id: "recipe.v1" },
      arguments: { actor_ref: "" }
    )
    refute response["ok"]
    assert_equal "invalid_request", response.dig("error", "code")

    response = @app.call(protocol: "jazari/v1", request_id: "missing", action: "capabilities")
    refute response["ok"]
    assert_equal "invalid_request", response.dig("error", "code")

    response = @app.call(
      protocol: "jazari/v1", request_id: "confirm", action: "reset",
      target: { kind: "anchor", scope_type: "local", scope_id: 1,
                key: "one", recipe_id: "recipe.v1" },
      arguments: { expected_revision: "one", confirm: "yes" }
    )
    refute response["ok"]
    assert_equal "invalid_request", response.dig("error", "code")
  end

  def test_every_shared_conformance_fixture_passes_on_sqlite
    run_conformance_fixtures
  end

  def test_cli_and_mcp_are_projections_of_the_same_dispatcher
    request = {
      protocol: "jazari/v1", request_id: "cap", action: "capabilities", arguments: {}
    }
    stdout, stderr, status = Open3.capture3(
      { "JAZARI_DATABASE" => @database },
      Gem.ruby, "-Ilib", "exe/jazari", "call", stdin_data: JSON.generate(request), chdir: File.expand_path("..", __dir__)
    )
    assert status.success?, stderr
    assert_equal "sqlite", JSON.parse(stdout).dig("result", "storage")

    mcp_input = [
      { jsonrpc: "2.0", id: 1, method: "initialize", params: { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "test", version: "1" } } },
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { jsonrpc: "2.0", id: 2, method: "tools/list", params: {} }
    ].map { |message| JSON.generate(message) }.join("\n") + "\n"
    stdout, stderr, status = Open3.capture3(
      { "JAZARI_DATABASE" => @database },
      Gem.ruby, "-Ilib", "exe/jazari", "mcp", "stdio",
      stdin_data: mcp_input, chdir: File.expand_path("..", __dir__)
    )
    assert status.success?, stderr
    replies = stdout.lines.map { |line| JSON.parse(line) }
    assert_equal "2025-11-25", replies.first.dig("result", "protocolVersion")
    assert_equal "jazari", replies.last.dig("result", "tools", 0, "name")

    tool_schema = replies.last.dig("result", "tools", 0, "inputSchema")
    schemer = JSONSchemer.schema(tool_schema)
    queue = { "kind" => "queue", "key" => "queue", "recipe_id" => "recipe.v1" }
    assert schemer.valid?({ "action" => "get", "target" => queue })
    refute schemer.valid?({ "action" => "get", "target" => queue, "run_id" => 1 })
  end


  def test_stdio_ignores_blank_lines_and_returns_json_rpc_errors_without_crashing
    input = StringIO.new("\nnot-json\n" + [
      { jsonrpc: "2.0", id: { bad: true }, method: "ping" },
      { jsonrpc: "2.0", id: 4, method: "unknown" }
    ].map { |message| JSON.generate(message) }.join("\n") + "\n")
    output = StringIO.new

    Jazari::Mcp::StdioServer.new(dispatcher: @app.dispatcher).serve(input: input, output: output)
    replies = output.string.lines.map { |line| JSON.parse(line) }

    assert_equal [ -32_700, -32_600, -32_002 ], (replies.map { |reply| reply.dig("error", "code") })
  end

  def test_stdio_enforces_the_initialize_lifecycle_and_params
    server = Jazari::Mcp::StdioServer.new(dispatcher: @app.dispatcher)

    early = server.receive("jsonrpc" => "2.0", "id" => 1, "method" => "tools/list", "params" => {})
    assert_equal(-32_002, early.dig(:error, :code))

    invalid = server.receive("jsonrpc" => "2.0", "id" => 2, "method" => "initialize", "params" => {})
    assert_equal(-32_602, invalid.dig(:error, :code))

    initialized = server.receive(
      "jsonrpc" => "2.0", "id" => 3, "method" => "initialize",
      "params" => { "protocolVersion" => "2025-11-25", "capabilities" => {},
                    "clientInfo" => { "name" => "test", "version" => "1" } }
    )
    assert_equal "2025-11-25", initialized.dig(:result, :protocolVersion)
    server.receive("jsonrpc" => "2.0", "method" => "notifications/initialized")

    listed = server.receive("jsonrpc" => "2.0", "id" => 4, "method" => "tools/list", "params" => {})
    assert_equal "jazari", listed.dig(:result, :tools, 0, :name)

    unknown = server.receive("jsonrpc" => "2.0", "id" => 5, "method" => "unknown")
    assert_equal(-32_601, unknown.dig(:error, :code))

    Jazari::RecipeRegistry.seed!([ { id: "mcp.v1", topic: "MCP", checklist: [] } ])
    called = server.receive(
      "jsonrpc" => "2.0", "id" => 6, "method" => "tools/call",
      "params" => {
        "name" => "jazari",
        "arguments" => {
          "action" => "get",
          "target" => { "kind" => "queue", "key" => "mcp", "recipe_id" => "mcp.v1" }
        }
      }
    )
    assert_equal false, called.dig(:result, :isError)
    assert_equal "default", called.dig(:result, :structuredContent, "result", "state")

    bad_tool = server.receive(
      "jsonrpc" => "2.0", "id" => 7, "method" => "tools/call",
      "params" => { "name" => "other", "arguments" => {} }
    )
    assert_equal(-32_602, bad_tool.dig(:error, :code))
  end

  def test_cli_accepts_recipe_options_before_or_after_the_path
    recipe = File.join(@tmp, "recipe.yml")
    File.write(recipe, "id: cli.v1\ntopic: CLI\nchecklist: []\n")
    root = File.expand_path("..", __dir__)

    [
      [ "recipes", "seed", recipe, "--database", @database ],
      [ "recipes", "seed", "--database", @database, recipe ]
    ].each do |arguments|
      stdout, stderr, status = Open3.capture3(Gem.ruby, "-Ilib", "exe/jazari", *arguments, chdir: root)
      assert status.success?, stderr
      assert_equal "jazari/v1", JSON.parse(stdout).fetch("protocol")
    end
  end

  def test_protocol_documents_are_valid_json_and_shipped_by_the_gem
    root = File.expand_path("..", __dir__)
    schemas = Dir[File.join(root, "protocol/v1/*.schema.json")]
    assert_equal 4, schemas.length
    schemas.each do |path|
      document = JSON.parse(File.read(path))
      assert_empty JSONSchemer.validate_schema(document).to_a, File.basename(path)
    end

    files = Gem::Specification.load(File.join(root, "jazari.gemspec")).files
    assert_includes files, "exe/jazari"
    assert_includes files, "protocol/v1/request.schema.json"
    Dir.glob(Jazari::ConformanceRunner::FIXTURES).each do |path|
      assert_includes files, path.delete_prefix("#{root}/")
    end
  end

  private

  def reset_conformance_storage
    ActiveRecord::Base.connection_pool.disconnect!
    FileUtils.rm_f([ @database, "#{@database}-wal", "#{@database}-shm" ])
    @app = Jazari::Standalone::App.new(database: @database)
  end

  def conformance_dispatcher = @app.dispatcher
end
