# frozen_string_literal: true

require "date"
require "time"
require "active_record"
require "jazari"
require "jazari/mcp/handler"

module Jazari
  module Protocol
    class InvalidRequest < StandardError; end

    class Dispatcher
      VERSION = "jazari/v1"
      ACTIONS = ([ "capabilities" ] + Mcp::Actions::NAMES).freeze
      REQUEST_KEYS = %w[protocol request_id action target arguments].freeze
      DOMAIN_ERRORS = %w[
        target_not_found invalid_runbook revision_conflict item_not_found
        item_not_in_snapshot read_only_target run_closed
      ].freeze

      def initialize(handler: Mcp::Handler.new)
        @handler = handler
      end

      def capabilities
        adapter = Jazari::ApplicationRecord.connection.adapter_name.downcase
        storage = if adapter.include?("sqlite")
          "sqlite"
        elsif adapter.include?("postgres")
          "postgresql"
        else
          raise ActiveRecord::AdapterNotSpecified, "jazari/v1 does not support the #{adapter} adapter"
        end
        {
          protocol: VERSION,
          storage: storage,
          transports: storage == "sqlite" ? %w[cli mcp-stdio] : %w[ruby],
          features: %w[recipes runbooks runs evidence]
        }
      end

      def call(input)
        request = stringify(input)
        validate_request!(request)
        action = request.fetch("action")
        result = if action == "capabilities"
          capabilities
        else
          @handler.call(
            action: action,
            target: target_from(request.fetch("target")),
            arguments: request.fetch("arguments")
          )
        end

        envelope(request, result)
      rescue InvalidRequest => error
        error_envelope(input, "invalid_request", error.message)
      rescue ActiveRecord::RecordNotFound
        error_envelope(input, "target_not_found")
      rescue ActiveRecord::StatementInvalid => error
        code = sqlite_busy?(error) ? "storage_busy" : "storage_failure"
        error_envelope(input, code)
      rescue StandardError
        error_envelope(input, "storage_failure")
      end

      private

      def validate_request!(request)
        invalid!("request must be an object") unless request.is_a?(Hash)
        unknown = request.keys - REQUEST_KEYS
        invalid!("unknown request fields: #{unknown.join(', ')}") if unknown.any?
        invalid!("protocol must be #{VERSION}") unless request["protocol"] == VERSION
        invalid!("request_id must be a non-empty string") unless request["request_id"].is_a?(String) && !request["request_id"].empty?

        action = request["action"]
        invalid!("unknown action #{action.inspect}") unless ACTIONS.include?(action)
        invalid!("arguments is required") unless request.key?("arguments")
        arguments = request["arguments"]
        invalid!("arguments must be an object") unless arguments.is_a?(Hash)

        if action == "capabilities"
          invalid!("capabilities does not accept a target") if request.key?("target")
          invalid!("capabilities does not accept arguments") unless arguments.empty?
          return
        end

        invalid!("target is required") unless request["target"].is_a?(Hash)
        validate_arguments!(action, arguments)
      end

      def validate_arguments!(action, arguments)
        descriptor = Mcp::Actions.fetch(action)
        allowed = descriptor.params.keys.map(&:to_s)
        unknown = arguments.keys - allowed
        invalid!("unknown #{action} arguments: #{unknown.join(', ')}") if unknown.any?
        missing = descriptor.required.map(&:to_s) - arguments.keys
        invalid!("missing #{action} arguments: #{missing.join(', ')}") if missing.any?

        arguments.each do |key, value|
          validate_type!(key, value, descriptor.params.fetch(key.to_sym))
        end
      end

      def validate_type!(key, value, schema)
        valid = case schema[:type]
        when "string" then value.is_a?(String)
        when "integer" then value.is_a?(Integer)
        when "boolean" then value == true || value == false
        when "array" then value.is_a?(Array)
        else true
        end
        invalid!("#{key} must be a #{schema[:type]}") unless valid
        invalid!("#{key} must be #{schema[:const].inspect}") if schema.key?(:const) && value != schema[:const]
        invalid!("unknown #{key} #{value.inspect}") if schema[:enum] && !schema[:enum].include?(value)
        invalid!("#{key} must be at least #{schema[:minimum]}") if schema[:minimum] && value < schema[:minimum]
        validate_value!(key, value)
      end

      def validate_value!(key, value)
        case key
        when "expected_revision", "actor_ref"
          invalid!("#{key} must not be empty") if value.empty?
        when "item_id"
          invalid!("item_id must not be empty") if value.empty?
        when "run_id"
          invalid!("run_id must be positive") unless value.positive?
        when "topic"
          invalid!("topic must not be empty") if value.empty?
          invalid!("topic exceeds #{Operations::MAX_TOPIC}") if value.length > Operations::MAX_TOPIC
        when "description"
          invalid!("description exceeds #{Operations::MAX_DESCRIPTION}") if value.length > Operations::MAX_DESCRIPTION
        when "note"
          invalid!("note exceeds #{Checklist::MAX_TEXT}") if value.length > Checklist::MAX_TEXT
        when "text"
          invalid!("text must not be empty") if value.empty?
          invalid!("text exceeds #{Checklist::MAX_TEXT}") if value.length > Checklist::MAX_TEXT
        when "checklist"
          validate_checklist!(value)
        when "kind"
          invalid!("unknown evidence kind #{value.inspect}") unless Runs::EVIDENCE_KINDS.include?(value)
        when "value"
          invalid!("evidence value exceeds #{Runs::MAX_EVIDENCE}") if value.length > Runs::MAX_EVIDENCE
        when "outcome"
          invalid!("unknown outcome #{value.inspect}") unless Run::OUTCOMES.include?(value)
        when "confirm"
          invalid!("confirm must be true") unless value
        end
      end

      def validate_checklist!(items)
        items.each do |item|
          invalid!("checklist items must be objects") unless item.is_a?(Hash)
          entry = stringify(item)
          unknown = entry.keys - %w[id text done required]
          invalid!("unknown checklist fields: #{unknown.join(', ')}") if unknown.any?
          invalid!("checklist item text is required") unless entry["text"].is_a?(String) && !entry["text"].empty?
          invalid!("checklist item text exceeds #{Checklist::MAX_TEXT}") if entry["text"].length > Checklist::MAX_TEXT
          invalid!("checklist item id is invalid") if entry.key?("id") &&
            (!entry["id"].is_a?(String) || !entry["id"].match?(Checklist::ID_FORMAT))
          %w[done required].each do |flag|
            invalid!("checklist item #{flag} must be a boolean") if entry.key?(flag) && ![ true, false ].include?(entry[flag])
          end
        end
      end

      def target_from(target)
        kind = target["kind"]
        case kind
        when "queue"
          exact_keys!(target, %w[kind key recipe_id public_reference])
          QueueTarget.new(
            queue: required_string(target, "key"),
            recipe_id: required_string(target, "recipe_id"),
            public_reference: public_reference(target)
          )
        when "anchor"
          exact_keys!(target, %w[kind scope_type scope_id key recipe_id public_reference])
          scope_type = required_string(target, "scope_type")
          AnchorTarget.new(
            scope_type: scope_type,
            scope_id: required_integer(target, "scope_id"),
            key: required_string(target, "key"),
            recipe_id: required_string(target, "recipe_id"),
            public_reference: public_reference(target)
          )
        else
          invalid!("target kind must be queue or anchor")
        end
      end

      def exact_keys!(value, allowed)
        unknown = value.keys - allowed
        invalid!("unknown target fields: #{unknown.join(', ')}") if unknown.any?
      end

      def required_string(value, key)
        result = value[key]
        invalid!("target #{key} must be a non-empty string") unless result.is_a?(String) && !result.empty?
        result
      end

      def required_integer(value, key)
        result = value[key]
        invalid!("target #{key} must be an integer") unless result.is_a?(Integer)
        result
      end

      def public_reference(target)
        fallback_keys = %w[kind scope_type scope_id key]
        value = target.fetch("public_reference", target.select { |key, _| fallback_keys.include?(key) })
        invalid!("target public_reference must be an object") unless value.is_a?(Hash)
        value
      end

      def envelope(request, result)
        normalized = normalize(result)
        if normalized.delete("ok") == false
          code = normalized.fetch("error")
          return error_envelope(request, DOMAIN_ERRORS.include?(code) ? code : "storage_failure")
        end

        normalized["revision"] = normalized["revision"].to_s if normalized.key?("revision")
        {
          "protocol" => VERSION,
          "request_id" => request.fetch("request_id"),
          "action" => request.fetch("action"),
          "ok" => true,
          "result" => normalized
        }
      end

      def error_envelope(input, code, detail = nil)
        request = input.is_a?(Hash) ? stringify(input) : {}
        error = { "code" => code }
        error["detail"] = detail.to_s unless detail.to_s.empty?
        {
          "protocol" => VERSION,
          "request_id" => request["request_id"].to_s,
          "action" => request["action"].to_s,
          "ok" => false,
          "error" => error
        }
      end

      def normalize(value)
        case value
        when Hash then value.to_h { |key, nested| [ key.to_s, normalize(nested) ] }
        when Array then value.map { |nested| normalize(nested) }
        when Time then value.utc.iso8601
        when Date then value.iso8601
        when NilClass then nil
        else value.respond_to?(:to_h) ? normalize(value.to_h) : value
        end
      end

      def stringify(value)
        return value unless value.is_a?(Hash)
        value.to_h { |key, nested| [ key.to_s, nested.is_a?(Hash) ? stringify(nested) : nested ] }
      end

      def sqlite_busy?(error)
        error.cause&.class&.name.to_s.include?("Busy") || error.message.include?("database is locked")
      end

      def invalid!(message) = raise InvalidRequest, message
    end
  end
end
