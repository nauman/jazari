# frozen_string_literal: true

module Jazari
  # One subject's override of the canon. Materialized on first customization —
  # never on read.
  class Runbook < ApplicationRecord
    self.table_name = "jazari_runbooks"

    belongs_to :runbookable, polymorphic: true

    validates :topic, presence: true, length: { maximum: 120 }
    validates :description, length: { maximum: 20_000 }
    # Recorded so divergence from the canon is queryable rather than invisible.
    validates :recipe_id, presence: true
  end
end
