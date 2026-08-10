# frozen_string_literal: true

require "rails/railtie"

module Jazari
  # Jazari is a plain gem, NOT an engine: it contributes no routes, controllers,
  # views, or assets, and a host should not have to mount anything to use it.
  #
  # But its models live in `app/models`, and nothing puts that on a host's
  # autoload path by itself. Without this the gem loads, `Jazari.resolve` is
  # callable, and the first call dies on `uninitialized constant
  # Jazari::RecipeRecord` — which is exactly how the first host adoption found
  # it. The gem's own suite had masked it with `require_relative`.
  #
  # A Railtie is the smallest thing that fixes it: autoload paths only, no
  # engine, nothing mounted.
  class Railtie < ::Rails::Railtie
    config.before_configuration do
      models = File.expand_path("../../app/models", __dir__)
      ActiveSupport::Dependencies.autoload_paths << models
      Rails.autoloaders.main.push_dir(models) if Rails.respond_to?(:autoloaders)
    end
  end
end
