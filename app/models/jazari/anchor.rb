# frozen_string_literal: true

module Jazari
  # A stable relational target for a subject that is not an ActiveRecord row:
  # a JSON-tree node, a file path, a DNS zone, a document. The scope is
  # host-registered; the gem ships no default scope naming any real model.
  class Anchor < ApplicationRecord
    # Resolved on EVERY call, not assigned at class-definition time.
    #
    # Assigning it eagerly made the binding depend on load order: under Zeitwerk
    # a host's `configure` runs before these constants autoload, so the
    # assignment never happened and the model silently kept the gem's default
    # name. A host adopting existing tables then queried tables that do not
    # exist. Reading config here removes the ordering question entirely.
    def self.table_name = Jazari.table_name_for(:anchors)

    has_one :runbook, as: :runbookable, dependent: :destroy

    validates :scope_type, presence: true
    validates :scope_id, presence: true
    validates :key, presence: true, uniqueness: { scope: %i[scope_type scope_id] }
  end
end
