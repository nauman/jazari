# frozen_string_literal: true

require "active_record"
require "fileutils"
require "json"
require "jazari"
require "jazari/mcp/handler"

require_relative "../../app/models/jazari/application_record"
require_relative "../../app/models/jazari/recipe_record"
require_relative "../../app/models/jazari/runbook"
require_relative "../../app/models/jazari/anchor"
require_relative "../../app/models/jazari/run"
require_relative "../generators/jazari/install/templates/create_jazari_tables"
require "jazari/standalone/database"
require "jazari/protocol/dispatcher"
require "jazari/mcp/stdio_server"

module Jazari
  module Standalone
    class App
      attr_reader :dispatcher

      def initialize(database:, recipes: [])
        Database.connect!(database)
        Array(recipes).each do |path|
          RecipeRegistry.seed!(RecipeFiles.load(path))
        end
        @dispatcher = Protocol::Dispatcher.new
      end

      def call(request) = dispatcher.call(request)
      def capabilities = dispatcher.capabilities
    end
  end
end
