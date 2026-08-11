# frozen_string_literal: true

require_relative "test_helper"
require "tmpdir"

# Recipes as files. The point is not "YAML instead of a table" — it is that the
# same data has a reviewable form, WITHOUT files silently overwriting what an
# operator changed at runtime.
class RecipeFilesTest < Minitest::Test
  def setup
    Jazari::Run.delete_all
    Jazari::Runbook.delete_all
    Jazari::RecipeRecord.delete_all
    Jazari.configure { |c| c.table_prefix = "jazari_" }
    @dir = Dir.mktmpdir("jazari-recipes")
  end

  def teardown = FileUtils.remove_entry(@dir)

  def write(name, body)
    File.write(File.join(@dir, name), body)
  end

  def valid_yaml(id: "deploy.v1")
    <<~YML
      id: #{id}
      topic: How a deploy is done
      description: |
        ## Purpose
        Why this exists.
      run_policy: once_per_calendar_day
      checklist:
        - id: free-port
          text: Confirm nothing else holds the published port
        - id: verify
          text: Verify the origin answers
          required: false
    YML
  end

  # --- loading ------------------------------------------------------------

  def test_a_directory_of_yaml_becomes_entries_seed_can_consume
    write("deploy.yml", valid_yaml)
    entries = Jazari::RecipeFiles.load(@dir)

    assert_equal 1, entries.length
    Jazari::RecipeRegistry.seed!(entries)

    recipe = Jazari::RecipeRegistry.fetch("deploy.v1")
    assert_equal "How a deploy is done", recipe.topic
    assert_equal 2, recipe.checklist.length
    assert recipe.once_per_calendar_day?
  end

  def test_json_is_accepted_too
    write("deploy.json", JSON.generate({ id: "j.v1", topic: "T", checklist: [ { id: "a", text: "x" } ] }))
    assert_equal "j.v1", Jazari::RecipeFiles.load(@dir).first[:id]
  end

  def test_a_single_file_path_works_as_well_as_a_directory
    write("deploy.yml", valid_yaml)
    assert_equal 1, Jazari::RecipeFiles.load(File.join(@dir, "deploy.yml")).length
  end

  def test_a_wrapping_recipes_key_is_unwrapped
    write("all.yml", "recipes:\n  - id: a.v1\n    topic: A\n  - id: b.v1\n    topic: B\n")
    assert_equal %w[a.v1 b.v1], Jazari::RecipeFiles.load(@dir).map { |e| e[:id] }
  end

  def test_non_recipe_files_in_the_directory_are_ignored
    write("deploy.yml", valid_yaml)
    write("README.md", "not a recipe")
    assert_equal 1, Jazari::RecipeFiles.load(@dir).length
  end

  # --- failing loudly at load, not silently at resolve --------------------

  # The reason a loader exists at all rather than "just call YAML.load_file":
  # an unknown key is a typo, and a typo that loads silently becomes a recipe
  # that resolves to something nobody wrote.
  def test_an_unknown_key_is_refused
    write("deploy.yml", "id: x.v1\ntopic: T\nchekclist: []\n")
    error = assert_raises(Jazari::InvalidRunbook) { Jazari::RecipeFiles.load(@dir) }
    assert_match(/unknown recipe keys: chekclist/, error.message)
  end

  def test_a_missing_topic_is_refused
    write("deploy.yml", "id: x.v1\n")
    assert_raises(Jazari::InvalidRunbook) { Jazari::RecipeFiles.load(@dir) }
  end

  def test_an_unknown_run_policy_is_refused
    write("deploy.yml", "id: x.v1\ntopic: T\nrun_policy: hourly\n")
    assert_raises(Jazari::InvalidRunbook) { Jazari::RecipeFiles.load(@dir) }
  end

  # A file must not be able to store an item the API would reject.
  def test_the_checklist_is_held_to_the_same_rules_as_the_api
    write("deploy.yml", "id: x.v1\ntopic: T\nchecklist:\n  - id: 'not a valid id'\n    text: x\n")
    assert_raises(Jazari::InvalidRunbook) { Jazari::RecipeFiles.load(@dir) }
  end

  def test_duplicate_ids_across_files_are_refused
    write("a.yml", valid_yaml)
    write("b.yml", valid_yaml)
    error = assert_raises(Jazari::InvalidRunbook) { Jazari::RecipeFiles.load(@dir) }
    assert_match(/duplicate recipe ids/, error.message)
  end

  def test_malformed_yaml_names_the_file
    write("broken.yml", "id: [unclosed\n")
    error = assert_raises(Jazari::InvalidRunbook) { Jazari::RecipeFiles.load(@dir) }
    assert_match(/broken\.yml/, error.message)
  end

  def test_a_missing_path_is_refused_rather_than_silently_seeding_nothing
    assert_raises(Jazari::InvalidRunbook) { Jazari::RecipeFiles.load(File.join(@dir, "nope")) }
  end

  # --- files seed, they do not sync ---------------------------------------

  # The load-bearing guarantee. Re-seeding from a file must NOT overwrite what an
  # operator changed at runtime — that is the same rule the runbook layer follows,
  # and the reason recipes are data rather than code in the first place.
  def test_reseeding_from_a_file_never_overwrites_an_operator_edit
    write("deploy.yml", valid_yaml)
    Jazari::RecipeRegistry.seed!(Jazari::RecipeFiles.load(@dir))
    Jazari::RecipeRecord.find_by(recipe_id: "deploy.v1").update!(topic: "Operator rewrote this")

    Jazari::RecipeRegistry.seed!(Jazari::RecipeFiles.load(@dir))

    assert_equal "Operator rewrote this", Jazari::RecipeRegistry.fetch("deploy.v1").topic
  end

  # --- drift is reported, never resolved ----------------------------------

  def test_drift_is_empty_when_the_row_matches_the_file
    write("deploy.yml", valid_yaml)
    entries = Jazari::RecipeFiles.load(@dir)
    Jazari::RecipeRegistry.seed!(entries)

    assert_empty Jazari::RecipeFiles.drift(entries)
  end

  def test_drift_names_the_fields_that_differ
    write("deploy.yml", valid_yaml)
    entries = Jazari::RecipeFiles.load(@dir)
    Jazari::RecipeRegistry.seed!(entries)
    Jazari::RecipeRecord.find_by(recipe_id: "deploy.v1").update!(topic: "Changed at runtime")

    report = Jazari::RecipeFiles.drift(entries)
    assert_equal 1, report.length
    assert_equal :differs, report.first[:state]
    assert_includes report.first[:fields], :topic
  end

  def test_drift_reports_a_recipe_that_was_never_seeded
    write("deploy.yml", valid_yaml)
    report = Jazari::RecipeFiles.drift(Jazari::RecipeFiles.load(@dir))

    assert_equal :missing, report.first[:state]
  end

  # --- the way back out ---------------------------------------------------

  # Without this the loop does not close: an operator's runtime fix could never
  # be reviewed or committed, so runtime editing would quietly become the thing
  # you avoid rather than the thing the design is built around.
  def test_dump_round_trips_through_load
    write("deploy.yml", valid_yaml)
    Jazari::RecipeRegistry.seed!(Jazari::RecipeFiles.load(@dir))
    Jazari::RecipeRecord.find_by(recipe_id: "deploy.v1").update!(topic: "Edited at runtime")

    out = Dir.mktmpdir("jazari-dump")
    begin
      Jazari::RecipeFiles.dump(out)
      reloaded = Jazari::RecipeFiles.load(out)

      assert_equal "Edited at runtime", reloaded.first[:topic]
      assert_equal "once_per_calendar_day", reloaded.first[:run_policy]
      assert_equal 2, reloaded.first[:checklist].length
      assert_empty Jazari::RecipeFiles.drift(reloaded), "an exported file must agree with what it came from"
    ensure
      FileUtils.remove_entry(out)
    end
  end
end
