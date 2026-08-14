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

  # The item exists — it just post-dates the snapshot this run froze at open.
  # A subclass, so a host that already rescues ItemNotFound keeps working, and
  # one that wants to tell "no such step" from "not this run's step" can.
  # Without the distinction a caller cannot choose between failing, retrying,
  # and proceeding, and ends up matching on prose.
  class ItemNotInSnapshot < ItemNotFound; end
  class ReadOnlyTarget < Error; end
  class RunClosed < Error; end
end
