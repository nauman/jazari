# frozen_string_literal: true

module Jazari
  # A stable relational target for a subject that is not an ActiveRecord row:
  # a JSON-tree node, a file path, a DNS zone, a document. The scope is
  # host-registered; the gem ships no default scope naming any real model.
  class Anchor < ApplicationRecord
    self.table_name = "jazari_anchors"

    has_one :runbook, as: :runbookable, dependent: :destroy

    validates :scope_type, presence: true
    validates :scope_id, presence: true
    validates :key, presence: true, uniqueness: { scope: %i[scope_type scope_id] }
  end
end
