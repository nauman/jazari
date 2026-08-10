# frozen_string_literal: true

module Jazari
  # One subject's override of the canon. Materialized on first customization —
  # never on read.
  class Runbook < ApplicationRecord
    # Resolved on EVERY call, not assigned at class-definition time.
    #
    # Assigning it eagerly made the binding depend on load order: under Zeitwerk
    # a host's `configure` runs before these constants autoload, so the
    # assignment never happened and the model silently kept the gem's default
    # name. A host adopting existing tables then queried tables that do not
    # exist. Reading config here removes the ordering question entirely.
    def self.table_name = Jazari.table_name_for(:runbooks)

    belongs_to :runbookable, polymorphic: true

    validates :topic, presence: true, length: { maximum: 120 }
    validates :description, length: { maximum: 20_000 }
    # Recorded so divergence from the canon is queryable rather than invisible.
    validates :recipe_id, presence: true
  end
end
