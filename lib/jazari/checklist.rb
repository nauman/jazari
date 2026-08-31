# frozen_string_literal: true

require "json"
require "securerandom"

module Jazari
  # Checklist items are validated as a whole document. Item identity is an
  # opaque token, never array position: MCP has to be able to check one item
  # without knowing where it sits.
  module Checklist
    # The real bound is BYTES, not rows.
    #
    # 50 was inherited from a host that already had it, never benchmarked. A
    # 50-item procedure measured live serializes to 17,252 bytes at 278
    # characters per step (codex, on the session-anchor board; the suite's
    # synthetic equivalent is 16,691, since real ids and text are not uniform), so the row cap was rejecting documents four times smaller than
    # what actually hurts — and would have accepted 50 steps of 500 characters,
    # which is nearly twice as large again.
    #
    # What breaks is a payload: a jsonb column, a run snapshot copied per run,
    # and an MCP response that has to fit in a context window. None of those
    # count rows.
    MAX_PAYLOAD = 65_536

    # There is deliberately NO row cap. The first draft kept one at 200 as a
    # "guard against absurdity" — but 200 was as unmeasured as the 50 it
    # replaced, and it would still have rejected a 201-step document sitting
    # well inside the byte bound for exactly the old reason.
    #
    # The absurdity case is already answered by measurement: a normalized
    # minimal step is 67 bytes — the generated id is 16 of them — so MAX_PAYLOAD
    # admits 992 of them and no more. One bound, derived, with nothing left to
    # pick out of the air. (An earlier draft of this comment said ~1,090 by
    # estimating the row at 60 bytes instead of measuring it after id
    # generation. Measured, not reasoned, is the whole point of the change.)
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
      normalized = list.map do |item|
        id = item[:id].to_s
        id = generate_id unless id.match?(ID_FORMAT) && !seen.include?(id)
        seen << id
        { id: id, text: item[:text].to_s, done: item[:done] == true,
          required: item.fetch(:required, true) == true }
      end
      bound!(normalized)
    end

    # Measured on the NORMALIZED STORED FORM — the string-keyed rows actually
    # written to jsonb — and never on the caller's input or on an MCP envelope.
    #
    # That choice is the whole contract. Input arrives in four shapes (symbol
    # keys, string keys, a YAML file, a Ruby literal) and an envelope differs
    # per host, so counting either would make the same document legal in one
    # path and illegal in another. The stored form is the one representation
    # every path converges on, and ids are already assigned by the time it
    # exists — so the number is deterministic and reproducible by a host that
    # wants to check before it calls.
    def payload_bytes(items) = serialized_bytes(stored_form(items))

    # Counts rows VERBATIM. A run snapshot carries a key the canonical checklist
    # does not (`post_snapshot`), and projecting it away before measuring would
    # undercount the value actually written — by a margin that grows with every
    # late step. Measure the bytes that land in the column.
    def serialized_bytes(rows) = JSON.generate(rows).bytesize

    def stored_form(items)
      items.map do |item|
        row = item.to_h.transform_keys(&:to_s)
        { "id" => row["id"].to_s, "text" => row["text"].to_s,
          "done" => row["done"] == true, "required" => row.fetch("required", true) == true }
      end
    end

    def bound!(items) = bound_bytes!(payload_bytes(items), items)

    # For rows that are already in their stored shape, extra keys included.
    def bound_stored!(rows) = bound_bytes!(serialized_bytes(rows), rows)

    def bound_bytes!(bytes, items)
      if bytes > MAX_PAYLOAD
        raise InvalidRunbook,
              "checklist payload is #{bytes} bytes, over the #{MAX_PAYLOAD} limit"
      end

      items
    end

    def validate!(items)
      raise InvalidRunbook, "checklist must be an array" unless items.is_a?(Array)

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
