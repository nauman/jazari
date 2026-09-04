# frozen_string_literal: true

require "json"
require "jazari/version"
require "jazari/mcp/actions"

module Jazari
  module Mcp
    class StdioServer
      PROTOCOL_VERSION = "2025-11-25"
      SUPPORTED_VERSIONS = %w[2024-11-05 2025-03-26 2025-06-18 2025-11-25].freeze

      def initialize(dispatcher:, version: Jazari::VERSION)
        @dispatcher = dispatcher
        @version = version
        @initialization_response_sent = false
        @initialized = false
      end

      def serve(input: $stdin, output: $stdout)
        input.each_line do |line|
          next if line.strip.empty?

          message = JSON.parse(line)
          response = receive(message)
          output.puts(JSON.generate(response)) if response
          output.flush
        rescue JSON::ParserError
          output.puts(JSON.generate(jsonrpc_error(nil, -32_700, "Parse error")))
          output.flush
        rescue StandardError
          id = message.is_a?(Hash) ? message["id"] : nil
          output.puts(JSON.generate(jsonrpc_error(id, -32_603, "Internal error")))
          output.flush
        end
        0
      end

      def receive(message)
        id = message.is_a?(Hash) ? message["id"] : nil
        return jsonrpc_error(id, -32_600, "Invalid Request") unless valid_message?(message)
        return receive_notification(message) unless message.key?("id")

        case message["method"]
        when "initialize" then initialize_response(message)
        when "ping" then empty_response(message)
        else
          return jsonrpc_error(message["id"], -32_002, "Server not initialized") unless @initialized

          operational_response(message)
        end
      end

      def operational_response(message)
        case message["method"]
        when "tools/list" then list_tools(message)
        when "tools/call" then call_tool(message)
        else jsonrpc_error(message["id"], -32_601, "Method not found")
        end
      end

      private

      def valid_message?(message)
        message.is_a?(Hash) && message["jsonrpc"] == "2.0" && message["method"].is_a?(String) &&
          (!message.key?("id") || message["id"].is_a?(String) || message["id"].is_a?(Numeric))
      end

      def initialize_response(message)
        return jsonrpc_error(message["id"], -32_600, "Already initialized") if @initialization_response_sent
        return jsonrpc_error(message["id"], -32_602, "Invalid params") unless valid_initialize_params?(message["params"])

        requested = message.dig("params", "protocolVersion")
        negotiated = SUPPORTED_VERSIONS.include?(requested) ? requested : PROTOCOL_VERSION
        @initialization_response_sent = true
        jsonrpc_result(
          message["id"],
          protocolVersion: negotiated,
          capabilities: { tools: { listChanged: false } },
          serverInfo: {
            name: "jazari", title: "Jazari", version: @version,
            description: "Addressable operating procedures and run evidence."
          },
          instructions: "Authorize the caller before constructing a target. Jazari records procedure state; it does not execute commands."
        )
      end

      def valid_initialize_params?(params)
        params.is_a?(Hash) && params["protocolVersion"].is_a?(String) &&
          params["capabilities"].is_a?(Hash) && params["clientInfo"].is_a?(Hash) &&
          params.dig("clientInfo", "name").is_a?(String) &&
          params.dig("clientInfo", "version").is_a?(String)
      end

      def receive_notification(message)
        if message["method"] == "notifications/initialized" && @initialization_response_sent
          @initialized = true
        end
        nil
      end

      def empty_response(message)
        return jsonrpc_error(message["id"], -32_602, "Invalid params") unless object_params?(message)

        jsonrpc_result(message["id"], {})
      end

      def list_tools(message)
        return jsonrpc_error(message["id"], -32_602, "Invalid params") unless object_params?(message)

        jsonrpc_result(message["id"], tools: [ tool ])
      end

      def object_params?(message)
        !message.key?("params") || message["params"].is_a?(Hash)
      end

      def tool
        {
          name: "jazari",
          title: "Jazari procedure state",
          description: "Resolve or update a procedure and record run evidence.",
          inputSchema: Actions.input_schema(target_schema: target_schema),
          annotations: {
            readOnlyHint: false, destructiveHint: true,
            idempotentHint: false, openWorldHint: false
          }
        }
      end

      def target_schema
        {
          oneOf: [
            {
              type: "object", required: %w[kind key recipe_id],
              properties: {
                kind: { const: "queue" }, key: { type: "string", minLength: 1 },
                recipe_id: { type: "string", minLength: 1 },
                public_reference: { type: "object" }
              },
              additionalProperties: false
            },
            {
              type: "object", required: %w[kind scope_type scope_id key recipe_id],
              properties: {
                kind: { const: "anchor" }, scope_type: { type: "string", minLength: 1 },
                scope_id: { type: "integer" }, key: { type: "string", minLength: 1 },
                recipe_id: { type: "string", minLength: 1 },
                public_reference: { type: "object" }
              },
              additionalProperties: false
            }
          ]
        }
      end

      def call_tool(message)
        params = message.fetch("params", {})
        return jsonrpc_error(message["id"], -32_602, "Unknown tool") unless params["name"] == "jazari"

        arguments = params.fetch("arguments", {})
        return jsonrpc_error(message["id"], -32_602, "Invalid params") unless arguments.is_a?(Hash)

        action = arguments["action"]
        target = arguments["target"]
        action_arguments = arguments.reject { |key, _| %w[action target].include?(key) }
        response = @dispatcher.call(
          "protocol" => Protocol::Dispatcher::VERSION,
          "request_id" => "mcp:#{message.fetch('id')}",
          "action" => action,
          "target" => target,
          "arguments" => action_arguments
        )
        result = {
          content: [ { type: "text", text: JSON.generate(response) } ],
          structuredContent: response,
          isError: response["ok"] == false
        }
        jsonrpc_result(message["id"], result)
      rescue KeyError, TypeError
        jsonrpc_error(message["id"], -32_602, "Invalid params")
      end

      def jsonrpc_result(id, result) = { jsonrpc: "2.0", id: id, result: result }

      def jsonrpc_error(id, code, message)
        { jsonrpc: "2.0", id: id, error: { code: code, message: message } }
      end
    end
  end
end
