# frozen_string_literal: true

module Jazari
  # A closed taxonomy. Hosts translate these into their own transport envelope;
  # unauthorized, unknown, deleted, and type-mismatched input must all collapse
  # to TargetNotFound so that guessing a target cannot disclose its existence.
  class Error < StandardError
    def code = self.class.name.split("::").last.gsub(/([a-z])([A-Z])/, '\1_\2').downcase
  end

  class TargetNotFound < Error; end
  class InvalidRunbook < Error; end
  class RevisionConflict < Error; end
  class ItemNotFound < Error; end
  class ReadOnlyTarget < Error; end
  class RunClosed < Error; end
end
