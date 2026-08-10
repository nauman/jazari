# frozen_string_literal: true

module Jazari
  # The runbook half: resolving a subject's operating truth and customizing it.
  #
  # Reading a default writes NOTHING — no row, no anchor, no audit noise. The
  # first customization materializes a record; reset destroys it and reveals the
  # current canon again, so a recipe correction reaches every subject that never
  # overrode it.
  module Operations
    MAX_TOPIC = 120
    MAX_DESCRIPTION = 20_000

    module_function

    def resolve(target:)
      recipe = RecipeRegistry.fetch(target.recipe_id)
      record = find_runbook(target)
      last = Runs.last(target: target)

      return custom_value(record, target, recipe, last) if record

      default_value(recipe, target, last)
    end

    def customize(target:, expected_revision:, topic:, description:, checklist:)
      writable!(target)
      validate_document!(topic, description)
      items = Checklist.normalize(checklist)
      write(target, expected_revision) do |current|
        current.merge(topic: topic, description: description, checklist: items)
      end
    end

    def add_item(target:, expected_revision:, text:, required: true)
      writable!(target)
      write(target, expected_revision) do |current|
        items = current[:checklist] + [
          { id: Checklist.generate_id, text: text.to_s, done: false, required: required == true }
        ]
        Checklist.validate!(items)
        current.merge(checklist: items)
      end
    end

    def remove_item(target:, expected_revision:, item_id:)
      writable!(target)
      write(target, expected_revision) do |current|
        remaining = current[:checklist].reject { |item| item[:id] == item_id.to_s }
        raise ItemNotFound, "unknown checklist item #{item_id}" if remaining.length == current[:checklist].length

        current.merge(checklist: remaining)
      end
    end

    def check_item(target:, expected_revision:, item_id:, done:)
      writable!(target)
      write(target, expected_revision) do |current|
        found = false
        items = current[:checklist].map do |item|
          next item unless item[:id] == item_id.to_s

          found = true
          item.merge(done: done == true)
        end
        raise ItemNotFound, "unknown checklist item #{item_id}" unless found

        current.merge(checklist: items)
      end
    end

    # Destroys the customization and reveals the current canon. Idempotent on an
    # already-default target only while the supplied default revision matches.
    def reset(target:, expected_revision:)
      writable!(target)
      record = find_runbook(target)
      if record
        record.with_lock do
          verify_custom_revision!(record, expected_revision)
          destroy_with_anchor(record)
        end
      else
        verify_default_revision!(target, expected_revision)
      end
      resolve(target: target)
    end

    # -- internals ---------------------------------------------------------

    # A queue is a stable name for a ritual, and a ritual has exactly one
    # editable home: its recipe. Per-subject customization belongs to subjects.
    def writable!(target)
      raise ReadOnlyTarget, "queues are read-only" if target.is_a?(QueueTarget)
    end
    private_class_method :writable!

    def write(target, expected_revision)
      record = find_runbook(target)
      if record
        record.with_lock do
          verify_custom_revision!(record, expected_revision)
          document = yield(current_document(record))
          record.update!(
            topic: document[:topic], description: document[:description],
            checklist: store_items(document[:checklist])
          )
        end
      else
        create_custom(target, expected_revision) { |current| yield(current) }
      end
      resolve(target: target)
    end
    private_class_method :write

    def create_custom(target, expected_revision)
      verify_default_revision!(target, expected_revision)
      recipe = RecipeRegistry.fetch(target.recipe_id)
      document = yield(
        { topic: recipe.topic, description: recipe.description,
          checklist: recipe.checklist.map(&:dup) }
      )
      Runbook.create!(
        runbookable: runbookable_for(target),
        recipe_id: recipe.id,
        topic: document[:topic], description: document[:description],
        checklist: store_items(document[:checklist])
      )
    rescue ActiveRecord::RecordNotUnique
      raise RevisionConflict, "another writer materialized this runbook first"
    rescue ActiveRecord::RecordInvalid => error
      raise InvalidRunbook, error.message
    end
    private_class_method :create_custom

    def runbookable_for(target)
      case target
      when RecordTarget then target.runbookable
      when AnchorTarget
        Anchor.create_or_find_by!(scope_type: target.scope_type, scope_id: target.scope_id, key: target.key)
      else raise TargetNotFound, "unsupported target"
      end
    end
    private_class_method :runbookable_for

    def destroy_with_anchor(record)
      anchor = record.runbookable
      anchor.is_a?(Anchor) ? anchor.destroy! : record.destroy!
    end
    private_class_method :destroy_with_anchor

    def find_runbook(target)
      case target
      when RecordTarget then Runbook.find_by(runbookable: target.runbookable)
      when AnchorTarget
        anchor = Anchor.find_by(scope_type: target.scope_type, scope_id: target.scope_id, key: target.key)
        anchor && Runbook.find_by(runbookable: anchor)
      when QueueTarget then nil
      else raise TargetNotFound, "unsupported target"
      end
    end
    private_class_method :find_runbook

    # Transports deliver the revision as a string; lock_version is an integer.
    def verify_custom_revision!(record, expected_revision)
      return if record.lock_version.to_s == expected_revision.to_s

      raise RevisionConflict, "expected revision #{expected_revision}, actual #{record.lock_version}"
    end
    private_class_method :verify_custom_revision!

    def verify_default_revision!(target, expected_revision)
      current = "default:#{RecipeRegistry.fetch(target.recipe_id).digest}"
      return if expected_revision.to_s == current

      raise RevisionConflict, "expected #{expected_revision}, current default is #{current}"
    end
    private_class_method :verify_default_revision!

    def validate_document!(topic, description)
      raise InvalidRunbook, "topic is required" if topic.to_s.empty?
      raise InvalidRunbook, "topic exceeds #{MAX_TOPIC}" if topic.to_s.length > MAX_TOPIC
      raise InvalidRunbook, "description exceeds #{MAX_DESCRIPTION}" if description.to_s.length > MAX_DESCRIPTION
    end
    private_class_method :validate_document!

    def current_document(record)
      { topic: record.topic, description: record.description,
        checklist: stored_items(record.checklist) }
    end
    private_class_method :current_document

    def custom_value(record, target, recipe, last)
      ResolvedRunbook.new(
        state: "custom", revision: record.lock_version, topic: record.topic,
        description: record.description, checklist: stored_items(record.checklist),
        target_reference: target.public_reference, recipe: recipe.provenance,
        last_run: run_summary(last)
      )
    end
    private_class_method :custom_value

    def default_value(recipe, target, last)
      ResolvedRunbook.new(
        state: "default", revision: "default:#{recipe.digest}", topic: recipe.topic,
        description: recipe.description, checklist: recipe.checklist,
        target_reference: target.public_reference, recipe: recipe.provenance,
        last_run: run_summary(last)
      )
    end
    private_class_method :default_value

    # The field that makes "is this ritual actually happening?" answerable from
    # a single read.
    def run_summary(run)
      return nil unless run

      { id: run.id, outcome: run.outcome, started_at: run.started_at,
        finished_at: run.finished_at, open: run.open? }
    end
    private_class_method :run_summary

    def stored_items(items)
      Array(items).map do |item|
        row = item.to_h.transform_keys(&:to_s)
        { id: row["id"].to_s, text: row["text"].to_s,
          done: row["done"] == true, required: row.fetch("required", true) == true }
      end
    end
    private_class_method :stored_items

    def store_items(items)
      items.map do |item|
        { "id" => item[:id], "text" => item[:text],
          "done" => item[:done] == true, "required" => item.fetch(:required, true) == true }
      end
    end
    private_class_method :store_items
  end
end
