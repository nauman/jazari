# jazari 0.3.0 — provenance on the runbook.
#
# Nullable and additive, in one deploy, because nothing reads it yet and NULL is
# a truthful value: it means "this row predates provenance", which is exactly
# what every existing row is.
class AddJazariRunbookOrigin < ActiveRecord::Migration[7.1]
  def change
    add_column :jazari_runbooks, :origin, :string
  end
end
