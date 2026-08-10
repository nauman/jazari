# frozen_string_literal: true

module Jazari
  # Every operation returns this. Never an unsaved ActiveRecord object.
  ResolvedRunbook = Data.define(
    :state, :revision, :topic, :description, :checklist, :progress,
    :target_reference, :recipe, :last_run
  ) do
    def initialize(state:, revision:, topic:, description:, checklist:,
                   target_reference:, recipe:, last_run: nil)
      items = Checklist.freeze_items(checklist)
      super(
        state: state.freeze, revision: revision, topic: topic.freeze,
        description: description.freeze, checklist: items,
        progress: Checklist.progress(items).freeze,
        target_reference: target_reference.freeze, recipe: recipe.freeze,
        last_run: last_run.freeze
      )
    end

    def default? = state == "default"
    def custom?  = state == "custom"
  end
end
