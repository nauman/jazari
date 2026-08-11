# frozen_string_literal: true

require "yaml"
require "json"

module Jazari
  # Recipes as FILES — the version-controlled, reviewable form of the same data.
  #
  # This does not make files a second source of truth. `seed!` has always been
  # create-if-missing, so a file is a SEED, not a sync: the row wins once it
  # exists, because an operator editing a procedure at runtime is the whole
  # reason recipes are data rather than code.
  #
  # That is deliberate and it is the same rule the runbook layer already follows —
  # a customised runbook diverges permanently rather than rebasing, because
  # silently overwriting a deliberate edit with a change nobody saw is the worst
  # available outcome. Applying files on every deploy would do exactly that, one
  # layer up.
  #
  # The cost of that choice is drift: a file and a row can disagree and nothing
  # says so. So drift is REPORTED (`drift`) rather than resolved, and there is a
  # way back out (`dump`) — edit at runtime, export, review the diff in a pull
  # request, commit. The loop closes without anyone's work being overwritten.
  module RecipeFiles
    EXTENSIONS = %w[.yml .yaml .json].freeze

    # Keys a recipe file may carry. Anything else is a typo, and a typo that
    # loads silently becomes a recipe that resolves to something nobody wrote.
    KEYS = %i[id version topic description checklist run_policy].freeze

    module_function

    # Reads one file or every recipe file in a directory. Returns plain hashes,
    # ready for `RecipeRegistry.seed!` — which is why this is a loader and not a
    # registry: producing the data and storing it are separate concerns.
    def load(path)
      entries = Array(paths_for(path)).flat_map { |file| parse(file) }
      entries.each { |entry| validate!(entry) }
      ids = entries.map { |entry| entry[:id] }
      duplicated = ids.tally.select { |_, count| count > 1 }.keys
      raise InvalidRunbook, "duplicate recipe ids: #{duplicated.join(', ')}" if duplicated.any?

      entries
    end

    # Writes what is actually stored back out as YAML, one file per recipe.
    # This is the half that makes runtime editing safe to allow: whatever an
    # operator changed can be exported, diffed and committed.
    def dump(directory, recipes: RecipeRecord.order(:recipe_id))
      dir = File.expand_path(directory.to_s)
      Dir.mkdir(dir) unless Dir.exist?(dir)
      recipes.map do |record|
        file = File.join(dir, "#{record.recipe_id}.yml")
        File.write(file, YAML.dump(stringify(to_entry(record))))
        file
      end
    end

    # Which stored recipes disagree with their file definition, and how.
    #
    # Reported, never applied. A host decides what a difference means: on one
    # fleet a file is the reviewed truth and a divergent row is an incident; on
    # another the row is an operator's fix and the file is simply stale.
    def drift(entries)
      Array(entries).filter_map do |entry|
        attributes = normalize(entry)
        record = RecipeRecord.find_by(recipe_id: attributes[:id].to_s)
        next { id: attributes[:id], state: :missing } if record.nil?

        differing = KEYS.reject { |key| same?(key, attributes, record) }
        next if differing.empty?

        { id: attributes[:id], state: :differs, fields: differing }
      end
    end

    # -- internals ---------------------------------------------------------

    def paths_for(path)
      expanded = File.expand_path(path.to_s)
      return [ expanded ] if File.file?(expanded)
      raise InvalidRunbook, "no such recipe path: #{path}" unless File.directory?(expanded)

      Dir.children(expanded).sort
         .select { |name| EXTENSIONS.include?(File.extname(name)) }
         .map { |name| File.join(expanded, name) }
    end

    def parse(file)
      raw = File.read(file)
      data = if File.extname(file) == ".json"
        JSON.parse(raw)
      else
        # safe_load: a recipe file is operational content, never a place to
        # instantiate arbitrary objects.
        YAML.safe_load(raw, permitted_classes: [], aliases: false)
      end
      # A file is either one recipe, a list of them, or a list under a `recipes:`
      # key. `Array(hash)` would explode a single recipe into key/value pairs, so
      # the Hash cases are named rather than coerced.
      entries = if data.is_a?(Hash)
        data.key?("recipes") ? Array(data["recipes"]) : [ data ]
      else
        Array(data)
      end
      entries.map { |entry| normalize(entry) }
    rescue JSON::ParserError, Psych::SyntaxError => error
      raise InvalidRunbook, "#{File.basename(file)}: #{error.message}"
    end

    def normalize(entry)
      entry.to_h.transform_keys { |key| key.to_s.to_sym }
    end

    def validate!(entry)
      unknown = entry.keys - KEYS
      raise InvalidRunbook, "unknown recipe keys: #{unknown.join(', ')}" if unknown.any?
      raise InvalidRunbook, "recipe id is required" if entry[:id].to_s.empty?
      raise InvalidRunbook, "recipe #{entry[:id]} has no topic" if entry[:topic].to_s.empty?

      policy = entry.fetch(:run_policy, RunPolicy::UNRESTRICTED).to_s
      unless RunPolicy::ALL.include?(policy)
        raise InvalidRunbook, "recipe #{entry[:id]} has unknown run_policy #{policy}"
      end

      # Reuse the one checklist validator rather than writing a second, laxer
      # one here — a file must not be able to store an item the API would reject.
      items = entry.fetch(:checklist, [])
      Checklist.normalize(items)

      # STRICTER than the API on one point, deliberately. `normalize` REPLACES an
      # unusable id with a generated one, which is right when an id is absent and
      # opaque. In a file it is neither: someone wrote it, MCP addresses the step
      # by it, and documentation quotes it. Silently swapping it for a random
      # token would put the file and the row into exactly the disagreement this
      # loader exists to prevent — so a malformed id is an error, not a fixup.
      Array(items).each do |item|
        id = (item[:id] || item["id"]).to_s
        next if id.empty? || id.match?(Checklist::ID_FORMAT)

        raise InvalidRunbook, "recipe #{entry[:id]}: checklist id #{id.inspect} is not a valid token"
      end

      entry
    end

    def to_entry(record)
      { id: record.recipe_id, version: record.version, topic: record.topic,
        description: record.description, run_policy: record.run_policy,
        checklist: Checklist.normalize(record.checklist) }
    end

    def stringify(value)
      case value
      when Hash then value.to_h { |key, inner| [ key.to_s, stringify(inner) ] }
      when Array then value.map { |inner| stringify(inner) }
      when Symbol then value.to_s
      else value
      end
    end

    def same?(key, attributes, record)
      stored = case key
      when :id then record.recipe_id
      when :checklist then Checklist.normalize(record.checklist)
      else record.public_send(key)
      end
      expected = key == :checklist ? Checklist.normalize(attributes.fetch(key, [])) : attributes[key]
      return true if expected.nil? && key != :id

      stringify(stored) == stringify(expected)
    end
  end
end
