# frozen_string_literal: true

module Jazari
  # Every operation returns this. Never an unsaved ActiveRecord object.
  ResolvedRunbook = Data.define(
    :state, :revision, :topic, :description, :checklist, :progress,
    :target_reference, :recipe, :last_run, :origin
  ) do
    def initialize(state:, revision:, topic:, description:, checklist:,
                   target_reference:, recipe:, last_run: nil, origin: nil)
      items = Checklist.freeze_items(checklist)
      super(
        state: state.freeze, revision: revision, topic: topic.freeze,
        description: description.freeze, checklist: items,
        progress: Checklist.progress(items).freeze,
        target_reference: target_reference.freeze, recipe: recipe.freeze,
        last_run: last_run.freeze, origin: origin&.freeze
      )
    end

    def default? = state == "default"
    def custom?  = state == "custom"

    # `custom?` answers "does a row exist", which is not the same question as
    # "did someone decide this". A backfill materializes a row for every subject
    # it touches, so a host reading `custom?` as divergence sees 100% divergence
    # the morning after a migration and learns nothing from it.
    #
    # Comparing content against the canon does not separate them either: a
    # backfilled runbook genuinely differs, because it carries the steps the
    # subject actually had. Only provenance can, so only provenance is asked.
    def inherited? = custom? && !origin.nil?

    # Divergence someone chose: a row that exists, with nothing claiming to have
    # manufactured it.
    def diverged? = custom? && origin.nil?
  end
end
