defmodule AcceptanceHarness.IncrementalSelectionTest do
  use ExUnit.Case, async: true

  alias AcceptanceHarness.IncrementalSelection

  @scenarios [
    %{
      "id" => "participant",
      "source_file" => "test/participant.exs",
      "tags" => ["participant", "survey"],
      "roles" => ["Participant"],
      "metadata" => %{"capability" => "session-continuity", "value_stream" => "participants"}
    },
    %{
      "id" => "admin",
      "source_file" => "test/admin.exs",
      "tags" => ["admin"],
      "roles" => ["Superadmin"],
      "metadata" => %{"capability" => "operations", "value_stream" => "operations"}
    },
    %{
      "id" => "public",
      "source_file" => "test/public.exs",
      "tags" => ["public"],
      "roles" => ["Visitor"],
      "metadata" => %{"capability" => "discovery", "value_stream" => "public"}
    }
  ]

  test "markers and paths broaden the mandatory fast set" do
    plan =
      IncrementalSelection.plan(@scenarios,
        aliases: %{"participants" => "participant", "surveys" => "survey"},
        mandatory_ids: ["public"],
        commit_messages: ["Improve reminders #surveys"],
        changed_paths: ["lib/participants/reminder.ex"],
        path_rules: [%{"pattern" => "lib/participants/**", "areas" => ["participant"]}]
      )

    assert plan.mode == "incremental"
    assert plan.fast.scenario_ids == ["participant", "public"]
    assert plan.remaining.scenario_ids == ["admin"]
  end

  test "unknown markers, unmapped paths, and shared paths force the full suite" do
    assert %{mode: "full", reason: reason} =
             IncrementalSelection.plan(@scenarios, commit_messages: ["Change #mystery"])

    assert reason =~ "unknown commit area"

    assert %{mode: "full", reason: reason} =
             IncrementalSelection.plan(@scenarios, changed_paths: ["lib/unknown.ex"])

    assert reason =~ "no safe acceptance mapping"

    assert %{mode: "full", reason: reason} =
             IncrementalSelection.plan(@scenarios,
               changed_paths: ["lib/shared/router.ex"],
               full_suite_paths: ["lib/shared/**"]
             )

    assert reason =~ "requires the full suite"
  end

  test "a numeric issue reference is not treated as an area marker" do
    plan =
      IncrementalSelection.plan(@scenarios,
        commit_messages: ["Fix participant flow #123"],
        changed_paths: ["lib/participants/profile.ex"],
        path_rules: [%{"pattern" => "lib/participants/**", "areas" => ["participant"]}]
      )

    assert plan.mode == "incremental"
  end
end
