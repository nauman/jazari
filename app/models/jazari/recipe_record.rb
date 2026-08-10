# frozen_string_literal: true

module Jazari
  # The persisted canon. Deliberately named RecipeRecord, not Recipe: `Recipe`
  # is the immutable value the domain passes around, and letting an ActiveRecord
  # object wear that name is how unsaved records leak into return values.
  class RecipeRecord < ApplicationRecord
    self.table_name = "jazari_recipes"

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
