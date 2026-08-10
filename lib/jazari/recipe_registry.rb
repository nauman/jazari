# frozen_string_literal: true

module Jazari
  # Recipes are data, not code. The gem owns the lookup mechanism, the
  # digest-based default-revision guard, an idempotent seed, and one
  # content-free fallback. It ships no recipe content.
  #
  # A missing recipe is not an error and performs zero writes.
  module RecipeRegistry
    EMPTY = Recipe.new(
      id: "core.empty.v1", version: 1, topic: "", description: "",
      checklist: [], run_policy: RunPolicy::UNRESTRICTED
    ).freeze

    module_function

    def fetch(recipe_id)
      RecipeRecord.find_by(recipe_id: recipe_id.to_s)&.to_recipe || EMPTY
    end

    # Create-if-missing. Existing records are operator-owned: reseeding never
    # overwrites them, because the operator's edit is the truth once it exists.
    def seed!(entries)
      Array(entries).map do |entry|
        attributes = entry.to_h.transform_keys(&:to_sym)
        items = Checklist.normalize(attributes.fetch(:checklist, []))
        RecipeRecord.find_or_create_by!(recipe_id: attributes.fetch(:id).to_s) do |record|
          record.version     = attributes.fetch(:version, 1)
          record.topic       = attributes.fetch(:topic)
          record.description = attributes.fetch(:description, "").to_s
          record.run_policy  = attributes.fetch(:run_policy, RunPolicy::UNRESTRICTED)
          record.checklist   = items.map { |item| item.transform_keys(&:to_s) }
        end
      end
    end
  end
end
