# frozen_string_literal: true

module Jazari
  # Isolated base class. A host may point this at its own connection; the gem
  # never assumes it shares a database with the host's own models, which is why
  # no cross-database foreign key is ever claimed (spec 02, D9).
  class ApplicationRecord < ActiveRecord::Base
    self.abstract_class = true
  end
end
