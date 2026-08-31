# frozen_string_literal: true

# The descriptors quote the domain's own limits rather than restating them, so
# the schema cannot drift from the validator. That means this file needs
# Checklist even when it is required on its own — which the standalone-require
# test exists to catch, and did.
require "jazari/checklist"

module Jazari
  module Mcp
    # Declarative descriptors for every action, so a host can absorb jazari into
    # ITS OWN tool instead of adopting this gem's handler.
    #
    # Without these, a host has two bad choices: take `Mcp::Handler`'s reply
    # shape wholesale, or hand-write the action list and let it drift from the
    # gem it describes. Neither is acceptable for a host that already has an
    # MCP surface with its own envelope, naming, and permission model.
    #
    # These descriptors are the single source of truth: `Handler` validates and
    # scopes against them too, so the schema a host publishes and the behaviour
    # the gem implements cannot diverge.
    module Actions
      # effect drives how a host should annotate the action to its clients:
      #   :read        — no writes
      #   :additive    — writes, but cannot destroy prior state
      #   :overwrite   — may replace an operator's content; annotate cautiously
      #   :destructive — removes something; gate it
      Action = Data.define(:name, :scope, :effect, :summary, :params, :confirm) do
        def read? = scope == :read
        def confirm? = confirm == true
        def to_h = { name: name, scope: scope, effect: effect, summary: summary,
                     params: params, confirm: confirm }
      end

      REVISION = { type: "string",
                   description: "The revision from the read immediately before this call." }.freeze
      # JSON Schema patterns are ECMAScript, which has no `\A`/`\z`. Publishing
      # Ruby's source verbatim hands validators an anchor they may reject or,
      # worse, read as a literal — so translate the anchors and keep everything
      # else derived from ID_FORMAT, which stays the single source of truth.
      ID_PATTERN = Checklist::ID_FORMAT.source.sub('\\A', "^").sub('\\z', "$").freeze

      ITEM_ID  = { type: "string", description: "Opaque checklist item id." }.freeze

      # An `array` with no `items` is not a contract, it is a guess. A client
      # generating from that descriptor is free to infer `string[]`, send
      # `["step one"]`, and be rejected by the domain with "checklist item must
      # be a hash" — which is what happened. The schema must publish the shape
      # the validator actually enforces, or the descriptor is documentation
      # that disagrees with the code.
      CHECKLIST_ITEM = {
        type: "object",
        required: [ "text" ],
        properties: {
          id: { type: "string", pattern: ID_PATTERN, maxLength: 64,
                description: "Opaque id. Omit to have one generated; send it back to keep a step " \
                             "stable across edits. An id that does not match the pattern is REPLACED " \
                             "with a generated one rather than rejected." },
          # minLength/maxLength, not just "string": empty text and 501 characters
          # are both rejected by the domain, and a schema that admits them makes
          # the client discover it at call time.
          text: { type: "string", minLength: 1, maxLength: Checklist::MAX_TEXT,
                  description: "The step. Required, non-empty." },
          done: { type: "boolean", description: "Default false." },
          required: { type: "boolean", description: "Whether the step gates completion. Default true." }
        },
        additionalProperties: false
      }.freeze

      # The one domain rule JSON Schema cannot express is the aggregate byte
      # bound, so it is DISCLOSED rather than left for the client to discover by
      # being rejected. An undocumented limit is the same failure as an untyped
      # array: the schema knows something the caller does not.
      CHECKLIST = { type: "array", items: CHECKLIST_ITEM,
                    description: "Full checklist; replaces the existing one. There is no row limit, " \
                                 "but the serialized checklist must be at most " \
                                 "#{Checklist::MAX_PAYLOAD} bytes." }.freeze
      RUN_ID   = { type: "integer", description: "The run returned by start." }.freeze
      ACTOR    = { type: "string", description: "Opaque identity of who is acting." }.freeze

      ALL = [
        Action.new(name: "get", scope: :read, effect: :read, confirm: false,
                   summary: "Resolve the operating procedure for a target, with progress and last run.",
                   params: {}),
        Action.new(name: "last_run", scope: :read, effect: :read, confirm: false,
                   summary: "The most recent run for a target — answers whether the ritual actually happened.",
                   params: {}),
        Action.new(name: "set", scope: :write, effect: :overwrite, confirm: false,
                   summary: "Replace this subject's procedure. Materialises an override on first use.",
                   params: { expected_revision: REVISION,
                             topic: { type: "string", description: "Short title." },
                             description: { type: "string", description: "Markdown body." },
                             checklist: CHECKLIST }),
        Action.new(name: "add_item", scope: :write, effect: :additive, confirm: false,
                   summary: "Append one checklist step.",
                   params: { expected_revision: REVISION,
                             text: { type: "string", description: "The step." },
                             required: { type: "boolean", description: "Whether the step is required. Default true." } }),
        Action.new(name: "remove_item", scope: :write, effect: :destructive, confirm: false,
                   summary: "Delete one checklist step.",
                   params: { expected_revision: REVISION, item_id: ITEM_ID }),
        Action.new(name: "check_item", scope: :write, effect: :additive, confirm: false,
                   summary: "Mark a step done or not done.",
                   params: { expected_revision: REVISION, item_id: ITEM_ID,
                             done: { type: "boolean", description: "Default true." } }),
        Action.new(name: "reset", scope: :write, effect: :destructive, confirm: true,
                   summary: "Discard this subject's override and reveal the current canon.",
                   params: { expected_revision: REVISION,
                             confirm: { type: "boolean", description: "Must be true — this discards operator content." } }),
        Action.new(name: "start", scope: :write, effect: :additive, confirm: false,
                   summary: "Open a run. Under a once-per-day recipe this returns the existing run instead of erroring.",
                   params: { actor_ref: ACTOR }),
        Action.new(name: "tick", scope: :write, effect: :additive, confirm: false,
                   summary: "Record a step done within a run. Does not touch the subject's own checklist.",
                   params: { run_id: RUN_ID, expected_revision: REVISION, item_id: ITEM_ID,
                             done: { type: "boolean", description: "Default true." },
                             actor_ref: ACTOR,
                             note: { type: "string", description: "Optional free text." } }),
        Action.new(name: "evidence", scope: :write, effect: :additive, confirm: false,
                   summary: "Attach evidence to a run: output, url, sha, count, or note.",
                   params: { run_id: RUN_ID, expected_revision: REVISION, item_id: ITEM_ID,
                             kind: { type: "string", description: "One of: output, url, sha, count, note." },
                             value: { type: "string", description: "The evidence itself." },
                             actor_ref: ACTOR }),
        Action.new(name: "finish", scope: :write, effect: :additive, confirm: false,
                   summary: "Close a run with an outcome: completed, abandoned, or failed.",
                   params: { run_id: RUN_ID, expected_revision: REVISION,
                             outcome: { type: "string", description: "completed | abandoned | failed" } })
      ].freeze

      NAMES = ALL.map(&:name).freeze

      module_function

      # scope: :read advertises only the read-only subset. A read-scoped
      # connection should not SEE mutations in its tool list — offering them and
      # then refusing is a worse experience than not offering them.
      def all(scope: :write)
        scope.to_s == "read" ? ALL.select(&:read?) : ALL
      end

      def names(scope: :write) = all(scope: scope).map(&:name)

      def fetch(name)
        ALL.find { |action| action.name == name.to_s } or
          raise ArgumentError, "unknown runbook action #{name.inspect}"
      end

      # A fragment a host merges into its OWN tool's input schema. It deliberately
      # returns only the action enum and the parameter properties — the host owns
      # the tool name, the description, its own target params, and its reply
      # envelope. Nothing here presumes this gem's handler is in the loop.
      #
      #   frag = Jazari::Mcp::Actions.schema_fragment
      #   MY_TOOL[:input_schema][:properties].merge!(frag[:properties])
      #   MY_TOOL[:input_schema][:properties][:action][:enum] += frag[:enum]
      def schema_fragment(scope: :write)
        actions = all(scope: scope)
        properties = actions.each_with_object({}) do |action, acc|
          action.params.each { |key, spec| acc[key] ||= spec }
        end
        { enum: actions.map(&:name), properties: properties }
      end

      # Human-readable action list for a tool description or a paired skill.
      def summaries(scope: :write)
        all(scope: scope).map { |a| "#{a.name} — #{a.summary}" }
      end
    end
  end
end
