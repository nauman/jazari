# frozen_string_literal: true

# The handler dispatches against Mcp::Actions, so it must require it: a host may
# `require "jazari/mcp/handler"` on its own now that this layer is opt-in.
require "jazari/mcp/actions"

module Jazari
  module Mcp
    # Transport-neutral adapter between an MCP action name and the domain.
    #
    # It knows nothing about transport, authentication, or product naming. The
    # HOST owns tool identity — one flat `action`-enum tool per product, named
    # for that product — and the host authorizes the actor and constructs the
    # target BEFORE calling here. This class only maps action names onto domain
    # calls and shapes the reply.
    #
    # That split is deliberate: two products sharing this handler still present
    # their own tool, their own subject vocabulary, and their own permissions.
    class Handler
      # Actions are declared once, in Mcp::Actions, so the schema a host
      # publishes and the behaviour implemented here cannot drift apart.
      def self.actions_for(scope) = Actions.names(scope: scope)

      def call(action:, target:, arguments: {})
        args = symbolize(arguments)
        descriptor = Actions.fetch(action)   # raises on an unknown action

        reply(public_send(:"handle_#{descriptor.name}", target, args))
      rescue Jazari::Error => error
        # The closed taxonomy crosses the wire as a code, never as a message
        # that could disclose a record, a query, or whether a target exists.
        { ok: false, error: error.code }
      end

      # -- read ---------------------------------------------------------------

      def handle_get(target, _args) = Operations.resolve(target: target)

      def handle_last_run(target, _args)
        run = Runs.last(target: target)
        run ? run_view(run) : { last_run: nil }
      end

      # -- runbook ------------------------------------------------------------

      def handle_set(target, args)
        Operations.customize(
          target: target, expected_revision: args[:expected_revision],
          topic: args[:topic], description: args[:description].to_s,
          checklist: args.fetch(:checklist, [])
        )
      end

      def handle_add_item(target, args)
        Operations.add_item(target: target, expected_revision: args[:expected_revision],
                            text: args[:text], required: args.fetch(:required, true))
      end

      def handle_remove_item(target, args)
        Operations.remove_item(target: target, expected_revision: args[:expected_revision],
                               item_id: args[:item_id])
      end

      def handle_check_item(target, args)
        Operations.check_item(target: target, expected_revision: args[:expected_revision],
                              item_id: args[:item_id], done: args[:done])
      end

      # Destructive: it discards the operator's customization. The host must
      # gate this on explicit confirmation before calling.
      def handle_reset(target, args)
        unless args[:confirm] == true
          raise InvalidRunbook, "reset discards the customization and requires confirm: true"
        end

        Operations.reset(target: target, expected_revision: args[:expected_revision])
      end

      # -- runs ---------------------------------------------------------------

      def handle_start(target, args)
        result = Runs.open(target: target, actor_ref: args.fetch(:actor_ref))
        run_view(result[:run]).merge(created: result[:created], idempotent_reuse: result[:idempotent_reuse])
      end

      def handle_tick(_target, args)
        run = Runs.tick(run: args.fetch(:run_id), expected_revision: args[:expected_revision],
                        item_id: args[:item_id], done: args.fetch(:done, true),
                        actor_ref: args[:actor_ref], note: args[:note])
        run_view(run)
      end

      def handle_evidence(_target, args)
        run = Runs.attach_evidence(run: args.fetch(:run_id), expected_revision: args[:expected_revision],
                                   item_id: args[:item_id], kind: args.fetch(:kind),
                                   value: args.fetch(:value), actor_ref: args[:actor_ref])
        run_view(run)
      end

      def handle_finish(_target, args)
        run = Runs.close(run: args.fetch(:run_id), expected_revision: args[:expected_revision],
                         outcome: args.fetch(:outcome, "completed"))
        run_view(run)
      end

      private

      def reply(result)
        payload = result.respond_to?(:to_h) ? result.to_h : result
        { ok: true }.merge(payload)
      end

      def run_view(run)
        {
          run_id: run.id, revision: run.lock_version, recipe: run.recipe_id,
          started_at: run.started_at, started_on: run.started_on,
          finished_at: run.finished_at, outcome: run.outcome, open: run.open?,
          ticks: run.ticks, evidence: run.evidence
        }
      end

      def symbolize(arguments)
        arguments.to_h { |key, value| [ key.to_sym, value ] }
      end
    end
  end
end
