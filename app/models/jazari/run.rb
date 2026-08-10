# frozen_string_literal: true

module Jazari
  # One execution of a ritual. The layer that makes "did last night's run
  # actually complete?" a query instead of a guess.
  #
  # Immutable once closed. Ticks on a run never touch the subject's checklist —
  # that separation is the whole point: `reset` on a runbook must not be able to
  # destroy the record that the ritual ever ran.
  class Run < ApplicationRecord
    # Resolved on EVERY call, not assigned at class-definition time.
    #
    # Assigning it eagerly made the binding depend on load order: under Zeitwerk
    # a host's `configure` runs before these constants autoload, so the
    # assignment never happened and the model silently kept the gem's default
    # name. A host adopting existing tables then queried tables that do not
    # exist. Reading config here removes the ordering question entirely.
    def self.table_name = Jazari.table_name_for(:runs)

    belongs_to :subject, polymorphic: true, optional: true

    OUTCOMES = %w[completed abandoned failed].freeze

    validates :recipe_id, presence: true
    validates :source_digest, presence: true
    validates :actor_ref, presence: true
    validates :started_at, presence: true
    validates :started_on, presence: true
    validates :outcome, inclusion: { in: OUTCOMES }, allow_nil: true
    validates :idempotency_policy, inclusion: { in: RecipeRecord::POLICIES }

    def open?   = finished_at.nil?
    def closed? = !open?
  end
end
