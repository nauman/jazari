# frozen_string_literal: true

require "securerandom"

module Jazari
  # Checklist items are validated as a whole document. Item identity is an
  # opaque token, never array position: MCP has to be able to check one item
  # without knowing where it sits.
  module Checklist
    MAX_ITEMS = 50
    MAX_TEXT = 500
    ID_FORMAT = /\A[A-Za-z0-9_-]{1,64}\z/

    # `required` is part of the schema so a host with per-step gating can carry
    # it through a migration. Widened from the original three keys deliberately
    # (see spec 02) — a legacy three-key item must still validate.
    KEYS = %i[id text done required].freeze

    module_function

    def normalize(items)
      list = validate!(items)
      seen = []
      list.map do |item|
        id = item[:id].to_s
        id = generate_id unless id.match?(ID_FORMAT) && !seen.include?(id)
        seen << id
        { id: id, text: item[:text].to_s, done: item[:done] == true,
          required: item.fetch(:required, true) == true }
      end
    end

    def validate!(items)
      raise InvalidRunbook, "checklist must be an array" unless items.is_a?(Array)
      raise InvalidRunbook, "checklist exceeds #{MAX_ITEMS} items" if items.length > MAX_ITEMS

      items.map do |item|
        raise InvalidRunbook, "checklist item must be a hash" unless item.is_a?(Hash)

        entry = item.to_h { |key, value| [ key.to_sym, value ] }
        unknown = entry.keys - KEYS
        raise InvalidRunbook, "unknown checklist keys: #{unknown.join(', ')}" if unknown.any?
        raise InvalidRunbook, "checklist item text is required" if entry[:text].to_s.empty?
        raise InvalidRunbook, "checklist item text exceeds #{MAX_TEXT}" if entry[:text].to_s.length > MAX_TEXT

        entry
      end
    end

    def freeze_items(items)
      items.map { |item| item.transform_values(&:freeze).freeze }.freeze
    end

    def progress(items)
      done = items.count { |item| item[:done] }
      total = items.length
      { done: done, total: total, percent: total.zero? ? 0 : (done * 100) / total }
    end

    def generate_id = SecureRandom.urlsafe_base64(12)
  end
end
