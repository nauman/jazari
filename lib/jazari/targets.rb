# frozen_string_literal: true

module Jazari
  # Hosts authorize the actor FIRST, then construct exactly one of these. The
  # domain never accepts a raw id, an arbitrary record, or an actor.
  RecordTarget = Data.define(:runbookable, :public_reference, :recipe_id)

  # Any subject that is not an ActiveRecord row: a JSON-tree node, a file path,
  # a DNS zone, a document. `scope` is host-registered.
  AnchorTarget = Data.define(:scope_type, :scope_id, :key, :public_reference, :recipe_id)

  # A stable name for a ritual that outlives any record. Read-only by design:
  # a ritual has exactly one editable home, and that is its recipe.
  QueueTarget = Data.define(:queue, :public_reference, :recipe_id)
end
