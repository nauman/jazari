# frozen_string_literal: true

require "jazari/version"
require "jazari/errors"
require "jazari/checklist"
require "jazari/recipe"
require "jazari/targets"
require "jazari/anchors"
require "jazari/resolved_runbook"
require "jazari/recipe_registry"
require "jazari/recipe_files"
require "jazari/runs"
require "jazari/operations"
# The MCP layer is OPTIONAL. Descriptors are cheap and a host may want them to
# build its own tool, so they load; the handler does not, because a host with
# its own MCP surface never calls it.
#   require "jazari/mcp/handler"   # only if you want the ready-made dispatcher
require "jazari/mcp/actions"
require "jazari/railtie" if defined?(::Rails::Railtie)

# Addressable operating procedures.
#
#   RECIPE   the canon - how this ritual is done. Data, not code.
#   RUNBOOK  one subject's override of it.
#   QUEUE    a stable name for a ritual that outlives any record.
#   RUN      one execution - who, when, which ticks, what evidence.
#
# This module is the only public mutation interface. It never accepts a raw id,
# an arbitrary record, or an actor: hosts authorize first, then pass exactly one
# immutable target value.
module Jazari
  class << self
    attr_accessor :configuration
  end

  Configuration = Struct.new(:actor_ref, :on_subject_destroyed, :anchor_scopes,
                             :table_prefix, :table_names) do
    def initialize(*)
      super
      self.anchor_scopes ||= {}
      self.table_prefix  ||= "jazari_"
      # Per-table overrides. A prefix alone is not enough for a host adopting
      # tables it already has: existing names rarely follow one scheme, and
      # renaming live tables in the same deploy as a cut-over is exactly what
      # the adoption plan forbids. Any key omitted falls back to the prefix.
      self.table_names   ||= {}
      # Optional zero-argument provider for trusted system contexts. User and
      # agent callers should pass an explicit opaque actor_ref.
      self.actor_ref     = nil if actor_ref.nil?
    end

    # Fail at boot, not at first call.
    def validate!
      anchor_scopes.each_key do |scope|
        raise ArgumentError, "anchor scope #{scope.inspect} must be a String" unless scope.is_a?(String)
      end
      if actor_ref && !actor_ref.is_a?(String) &&
          !(actor_ref.respond_to?(:call) && actor_ref.respond_to?(:arity) && actor_ref.arity.zero?)
        raise ArgumentError, "actor_ref must be a String or zero-argument callable"
      end
      true
    end
  end

  TABLES = { recipes: "recipes", runbooks: "runbooks", anchors: "anchors", runs: "runs" }.freeze

  def self.configure
    self.configuration ||= Configuration.new
    yield configuration if block_given?
    configuration.validate!
    apply_table_names!
    configuration
  end

  def self.table_name_for(key)
    TABLES.fetch(key) # raise early on an unknown key
    config.table_names[key]&.to_s || "#{config.table_prefix}#{TABLES.fetch(key)}"
  end

  # Kept for hosts that call it explicitly; the models now resolve their own
  # names on every call, so nothing depends on this having run.
  def self.models_loaded? = const_defined?(:RecipeRecord)

  def self.apply_table_names! = models_loaded?

  def self.config = configuration || configure

  # The documented public interface (spec 02 section 3). `Runs` is the
  # implementation; these are the names hosts and the MCP handler call.
  class << self
    def open_run(target:, actor_ref: nil, now: Time.now.utc)
      Runs.open(target: target, actor_ref: actor_ref, now: now)
    end

    def tick(run:, expected_revision:, item_id:, done:, actor_ref: nil, note: nil)
      Runs.tick(run: run, expected_revision: expected_revision, item_id: item_id,
                done: done, actor_ref: actor_ref, note: note)
    end

    def attach_evidence(run:, expected_revision:, item_id:, kind:, value:, actor_ref: nil)
      Runs.attach_evidence(run: run, expected_revision: expected_revision,
                           item_id: item_id, kind: kind, value: value, actor_ref: actor_ref)
    end

    def close_run(run:, expected_revision:, outcome:)
      Runs.close(run: run, expected_revision: expected_revision, outcome: outcome)
    end

    def last_run(target:) = Runs.last(target: target)

    def resolve(target:) = Operations.resolve(target: target)

    def customize(target:, expected_revision:, topic:, description:, checklist:, origin: nil)
      Operations.customize(target: target, expected_revision: expected_revision,
                           topic: topic, description: description, checklist: checklist,
                           origin: origin)
    end

    def add_item(target:, expected_revision:, text:, required: true)
      Operations.add_item(target: target, expected_revision: expected_revision,
                          text: text, required: required)
    end

    def remove_item(target:, expected_revision:, item_id:)
      Operations.remove_item(target: target, expected_revision: expected_revision, item_id: item_id)
    end

    def check_item(target:, expected_revision:, item_id:, done:)
      Operations.check_item(target: target, expected_revision: expected_revision,
                            item_id: item_id, done: done)
    end

    def reset(target:, expected_revision:)
      Operations.reset(target: target, expected_revision: expected_revision)
    end

    # Call from the host's after-commit when a subject is destroyed. See
    # Operations.forget_subject — runs survive on purpose.
    def forget_subject(subject) = Operations.forget_subject(subject)
  end
end
