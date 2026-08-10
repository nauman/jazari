# frozen_string_literal: true

module Jazari
  # The persisted canon. Deliberately named RecipeRecord, not Recipe: `Recipe`
  # is the immutable value the domain passes around, and letting an ActiveRecord
  # object wear that name is how unsaved records leak into return values.
  class RecipeRecord < ApplicationRecord
    # Resolved on EVERY call, not assigned at class-definition time.
    #
    # Assigning it eagerly made the binding depend on load order: under Zeitwerk
    # a host's `configure` runs before these constants autoload, so the
    # assignment never happened and the model silently kept the gem's default
    # name. A host adopting existing tables then queried tables that do not
    # exist. Reading config here removes the ordering question entirely.
    def self.table_name = Jazari.table_name_for(:recipes)

    POLICIES = Jazari::RunPolicy::ALL

    validates :recipe_id, presence: true, uniqueness: true
    validates :version, presence: true
    validates :topic, presence: true, length: { maximum: 120 }
    validates :description, length: { maximum: 20_000 }
    validates :run_policy, inclusion: { in: POLICIES }

    def to_recipe
      Recipe.new(
        id: recipe_id, version: version, topic: topic, description: description,
        run_policy: run_policy,
        checklist: Array(checklist).map do |item|
          { id: item["id"].to_s, text: item["text"].to_s,
            done: item["done"] == true, required: item.fetch("required", true) == true }
        end
      )
    end
  end
end
