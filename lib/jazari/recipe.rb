# frozen_string_literal: true

require "digest"
require "json"

module Jazari
  # Whether a ritual may run more than once in a day is a property of the
  # RITUAL, not a global rule: verifying a backup should happen once a day;
  # triaging an incident may happen five times.
  module RunPolicy
    UNRESTRICTED = "unrestricted"
    ONCE_PER_CALENDAR_DAY = "once_per_calendar_day"
    ALL = [ UNRESTRICTED, ONCE_PER_CALENDAR_DAY ].freeze
  end

  # The canon. Content is data, not code — the gem ships no recipe content at
  # all, only this shape and the empty fallback. Editing a recipe changes its
  # digest, so outstanding default revisions conflict instead of drifting
  # silently under someone who is mid-checklist.
  Recipe = Data.define(:id, :version, :topic, :description, :checklist, :run_policy) do
    def initialize(id:, version:, topic:, description:, checklist:,
                   run_policy: RunPolicy::UNRESTRICTED)
      unless RunPolicy::ALL.include?(run_policy)
        raise InvalidRunbook, "unknown run_policy #{run_policy.inspect}"
      end

      super(
        id: id.freeze, version: version, topic: topic.freeze,
        description: description.freeze, checklist: Checklist.freeze_items(checklist),
        run_policy: run_policy.freeze
      )
    end

    def digest
      Digest::SHA256.hexdigest(
        JSON.generate([ id, version, topic, description, checklist, run_policy ])
      )[0, 16]
    end

    def once_per_calendar_day? = run_policy == RunPolicy::ONCE_PER_CALENDAR_DAY

    def provenance = { id: id, version: version, digest: digest }
  end
end
