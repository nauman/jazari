# frozen_string_literal: true

require "date"
require "time"

module Jazari
  # The Run layer.
  #
  # Idempotency is a property of the RECIPE, not a global rule: verifying a
  # backup should happen once a day; triaging an incident may happen five times.
  # Under `once_per_calendar_day` a partial unique index over
  # (recipe_id, COALESCE(subject_type,''), COALESCE(subject_id,0), started_on)
  # enforces it — the COALESCE matters because a bare NULL subject (a queue run)
  # would otherwise be unconstrained, since NULL != NULL in a unique index.
  module Runs
    module_function

    # Insert FIRST, then rescue the unique violation and select the winner.
    # A find-then-insert races under concurrent writers — the same defect class
    # the revision guard exists to prevent.
    def open(target:, actor_ref: nil, now: Time.now.utc)
      recipe = RecipeRegistry.fetch(target.recipe_id)
      resolved = Operations.resolve(target: target)
      subject = subject_for(target)
      started_at = now.utc
      actor_ref = resolve_actor_ref(actor_ref)

      attributes = {
        recipe_id: recipe.id,
        source_digest: recipe.digest,
        subject_type: subject&.class&.name,
        subject_id: subject&.id,
        actor_ref: actor_ref.to_s,
        started_at: started_at,
        # The UTC calendar day. Never server-local: one nightly ritual must not
        # land on two different days depending on which region's box called it.
        started_on: started_at.to_date,
        idempotency_policy: recipe.run_policy,
        # The run is bound to the canon it opened against. Without this, an
        # operator editing a recipe mid-run makes the in-flight run unable to
        # tick its own steps, and able to tick steps that did not exist when it
        # started. source_digest alone is provenance, not protection.
        # A subject may carry a deliberate runbook customization. The run must
        # snapshot the truth the caller resolved, not silently fall back to the
        # recipe and then reject the subject's own checklist item at tick time.
        checklist_snapshot: resolved.checklist.map { |i| i.transform_keys(&:to_s) },
        ticks: [], evidence: []
      }

      attempts = 0
      begin
        attempts += 1
        run = Run.create!(attributes)
        { run: run, created: true, idempotent_reuse: false }
      rescue ActiveRecord::RecordNotUnique => error
        # Only a once-per-day recipe can collide on the idempotency index. Any
        # other unique violation belongs to a constraint we do not own — a host
        # index, say — and must never be reinterpreted as reuse.
        raise unless recipe.once_per_calendar_day?

        existing = find_days_run(attributes)
        # The winner can be deleted between our failed INSERT and this SELECT.
        # Retry once: on the second pass the row is gone and the INSERT wins.
        retry if existing.nil? && attempts < 2

        # No row on the idempotency key means this violation came from some
        # OTHER constraint. Surfacing our own error here would hide the host's
        # real one, so re-raise theirs untouched.
        raise error if existing.nil?

        { run: existing, created: false, idempotent_reuse: true }
      end
    end

    def tick(run:, expected_revision:, item_id:, done:, actor_ref: nil, note: nil, now: Time.now.utc)
      mutate(run, expected_revision) do |record|
        raise RunClosed, "run #{record.id} is already closed" if record.closed?

        snapshot = stored(record.checklist_snapshot)
        if snapshot.empty?
          # Every run written by this gem carries its opening checklist. An
          # empty one means the row predates the snapshot column, so any
          # migration that adds it must backfill rather than default to [].
          raise InvalidRunbook, "run #{record.id} has no checklist snapshot; backfill required"
        end

        known = snapshot.map { |item| item["id"] }
        raise ItemNotFound, "unknown checklist item #{item_id}" unless known.include?(item_id.to_s)

        ticks = stored(record.ticks).reject { |t| t["id"] == item_id.to_s }
        ticks << { "id" => item_id.to_s, "done" => done == true, "at" => now.utc.iso8601,
                   "actor_ref" => resolve_actor_ref(actor_ref, fallback: record.actor_ref),
                   "note" => note&.to_s }
        record.ticks = ticks
      end
    end

    def attach_evidence(run:, expected_revision:, item_id:, kind:, value:, actor_ref: nil,
                        now: Time.now.utc)
      raise InvalidRunbook, "unknown evidence kind #{kind.inspect}" unless EVIDENCE_KINDS.include?(kind.to_s)

      mutate(run, expected_revision) do |record|
        raise RunClosed, "run #{record.id} is already closed" if record.closed?

        record.evidence = stored(record.evidence) + [
          { "item_id" => item_id&.to_s, "kind" => kind.to_s,
            "value" => value.to_s[0, MAX_EVIDENCE], "at" => now.utc.iso8601,
            "actor_ref" => resolve_actor_ref(actor_ref, fallback: record.actor_ref) }
        ]
      end
    end

    def close(run:, expected_revision:, outcome:, now: Time.now.utc)
      mutate(run, expected_revision) do |record|
        raise RunClosed, "run #{record.id} is already closed" if record.closed?
        raise InvalidRunbook, "unknown outcome #{outcome.inspect}" unless Run::OUTCOMES.include?(outcome.to_s)

        record.outcome = outcome.to_s
        record.finished_at = now.utc
      end
    end

    def last(target:)
      recipe_id = target.recipe_id.to_s
      subject = subject_for(target, strict: false)
      # An anchor target whose anchor does not exist yet cannot have runs. It
      # must NOT fall through to the nil-subject branch, which would return
      # queue runs belonging to a different target entirely.
      return nil if target.is_a?(AnchorTarget) && subject.nil?

      scope = Run.where(recipe_id: recipe_id)
      scope = if subject
        scope.where(subject_type: subject.class.name, subject_id: subject.id)
      else
        scope.where(subject_type: nil, subject_id: nil)
      end
      scope.order(started_at: :desc).first
    end

    # -- internals ---------------------------------------------------------

    EVIDENCE_KINDS = %w[output url sha count note].freeze
    MAX_EVIDENCE = 2_000

    def mutate(run, expected_revision)
      record = run.is_a?(Run) ? run : Run.find_by(id: run)
      raise TargetNotFound, "unknown run" unless record

      record.with_lock do
        unless record.lock_version.to_s == expected_revision.to_s
          raise RevisionConflict, "expected revision #{expected_revision}, actual #{record.lock_version}"
        end

        yield record
        record.save!
      end
      record
    end
    private_class_method :mutate

    def find_days_run(attributes)
      Run.where(
        recipe_id: attributes[:recipe_id],
        subject_type: attributes[:subject_type],
        subject_id: attributes[:subject_id],
        started_on: attributes[:started_on],
        idempotency_policy: attributes[:idempotency_policy]
      ).order(started_at: :desc).first
    end
    private_class_method :find_days_run

    # strict: true  — a write path; an unresolvable anchor fails closed.
    # strict: false — a read path; a not-yet-created anchor is simply absent.
    def subject_for(target, strict: true)
      case target
      when RecordTarget then target.runbookable
      when AnchorTarget then Anchors.resolve(target, strict: strict)
      when QueueTarget  then nil
      else raise TargetNotFound, "unsupported target"
      end
    end
    private_class_method :subject_for

    def stored(value) = Array(value).map { |h| h.to_h.transform_keys(&:to_s) }
    private_class_method :stored

    def resolve_actor_ref(explicit, fallback: nil)
      value = explicit || fallback || Jazari.config.actor_ref
      value = value.call if value.respond_to?(:call)
      value = value.to_s
      raise InvalidRunbook, "actor_ref is required" if value.empty?

      value
    end
    private_class_method :resolve_actor_ref
  end
end
