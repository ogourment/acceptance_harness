defmodule AcceptanceHarness.AdminStoreDbTest do
  use ExUnit.Case, async: false

  @moduletag :db

  alias AcceptanceHarness.AdminStore
  alias AcceptanceHarness.TestRepo

  setup do
    Ecto.Adapters.SQL.query!(TestRepo, "DROP TABLE IF EXISTS acceptance_harness_comments", [])
    AdminStore.install!(repo: TestRepo)

    Ecto.Adapters.SQL.query!(
      TestRepo,
      "TRUNCATE acceptance_harness_runs CASCADE",
      []
    )

    :ok
  end

  defp evidence(run_id, extra \\ %{}) do
    %{
      "title" => "Evidence",
      "run" => %{"id" => run_id},
      "scenarios" => [
        Map.merge(
          %{
            "id" => "checkout",
            "title" => "Checkout",
            "status" => "success",
            "order" => 1,
            "steps" => [
              step(run_id, "checkout", 1, "Open checkout"),
              step(run_id, "checkout", 2, "Pay"),
              step(run_id, "checkout", 3, "Confirmation")
            ]
          },
          extra
        )
      ]
    }
  end

  defp step(run_id, scenario_id, index, title, extra \\ %{}) do
    # Mimics Evidence: run-global monotonic sequences and run-specific ids.
    sequence = System.unique_integer([:positive, :monotonic])

    Map.merge(
      %{
        "id" => "#{scenario_id}-#{index}-#{run_id}-#{sequence}",
        "scenario_id" => scenario_id,
        "title" => title,
        "description" => "#{title} description",
        "sequence" => sequence,
        "screenshot" => %{"name" => "#{scenario_id}-#{index}.png"},
        "metadata" => %{"scenario_id" => scenario_id}
      },
      extra
    )
  end

  defp import_legacy_step_comparison_run!(run_id, generated_at, changed_title, changed_count) do
    changed_steps =
      1..changed_count
      |> Enum.map(fn index -> step(run_id, "changed", index, "#{changed_title} #{index}") end)

    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "run" => %{"id" => run_id, "generated_at" => generated_at},
        "scenarios" => [
          %{
            "id" => "stable",
            "title" => "Stable",
            "status" => "success",
            "order" => 1,
            "steps" => [step(run_id, "stable", 1, "Stable step")]
          },
          %{
            "id" => "changed",
            "title" => "Changed",
            "status" => "success",
            "order" => 2,
            "steps" => changed_steps
          }
        ]
      },
      repo: TestRepo
    )
  end

  test "install! leaves the retired comments table absent" do
    result =
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "SELECT to_regclass('acceptance_harness_comments')",
        []
      )

    assert result.rows == [[nil]]
  end

  test "imports an unreached step without screenshot metadata" do
    evidence =
      evidence("run-pending", %{
        "status" => "ignored",
        "steps" => [step("run-pending", "checkout", 1, "Puzzle solved", %{"screenshot" => nil})]
      })

    AdminStore.import_evidence_data!(evidence, repo: TestRepo)

    assert [%{screenshot: %{}}] =
             AdminStore.list_steps("run-pending", "checkout", repo: TestRepo)
  end

  test "backfills documented timing without inventing missing elapsed time" do
    evidence =
      evidence("run-timing", %{
        "duration_ms" => nil,
        "documented_step_ms" => nil,
        "steps" => [
          step("run-timing", "checkout", 1, "Open", %{"metadata" => %{"duration_ms" => 125}}),
          step("run-timing", "checkout", 2, "Pay", %{"metadata" => %{"duration_ms" => 375}})
        ]
      })

    AdminStore.import_evidence_data!(evidence, repo: TestRepo)

    assert %{scenarios: 1, documented_step_ms: 500} =
             AdminStore.backfill_timing_summaries!(repo: TestRepo, run_id: "run-timing")

    assert [%{documented_step_ms: 500, duration_ms: nil, undocumented_ms: nil}] =
             AdminStore.list_scenarios("run-timing", repo: TestRepo)
  end

  test "imports terminal surfaces and indexes their visible text" do
    terminal_step =
      step("run-terminal", "repo-health", 1, "Open repository health", %{
        "surface" => %{
          "kind" => "terminal",
          "text" => "Repository health\n⚠ a55ist  dirty (1 modified)",
          "columns" => 80,
          "rows" => 24
        },
        "artifacts" => [
          %{
            "type" => "terminal_ansi",
            "path" => "artifacts/repo-health/open.ansi",
            "label" => "Raw terminal output"
          }
        ]
      })

    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "run" => %{"id" => "run-terminal"},
        "scenarios" => [
          %{
            "id" => "repo-health",
            "title" => "Repository health",
            "status" => "success",
            "steps" => [terminal_step]
          }
        ]
      },
      repo: TestRepo
    )

    assert [step] = AdminStore.list_steps("run-terminal", "repo-health", repo: TestRepo)
    assert step.surface["kind"] == "terminal"
    assert step.surface["text"] =~ "dirty (1 modified)"
    assert [%{"type" => "terminal_ansi"}] = step.artifacts

    assert [%{scenario_id: "repo-health"}] =
             AdminStore.list_scenarios("run-terminal",
               repo: TestRepo,
               search: "dirty modified"
             )
  end

  test "imports message timelines and indexes every visible frame" do
    timeline_step =
      step("run-timeline", "health-progress", 1, "Health completes", %{
        "surface" => %{
          "kind" => "message_timeline",
          "channel" => "telegram",
          "frames" => [
            %{"at_ms" => 0, "operation" => "send", "state" => "accepted", "text" => "Working..."},
            %{
              "at_ms" => 5_300,
              "operation" => "edit",
              "state" => "complete",
              "text" => "Health complete in five seconds"
            }
          ]
        }
      })

    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "run" => %{"id" => "run-timeline"},
        "scenarios" => [
          %{
            "id" => "health-progress",
            "title" => "Health progress",
            "status" => "success",
            "steps" => [timeline_step]
          }
        ]
      },
      repo: TestRepo
    )

    assert [step] = AdminStore.list_steps("run-timeline", "health-progress", repo: TestRepo)
    assert step.surface["channel"] == "telegram"
    assert length(step.surface["frames"]) == 2

    assert [%{scenario_id: "health-progress"}] =
             AdminStore.list_scenarios("run-timeline",
               repo: TestRepo,
               search: "Health complete five seconds"
             )
  end

  test "finds the newest acceptance run corresponding to a deployment" do
    AdminStore.import_evidence_data!(
      Map.merge(evidence("run-old"), %{
        "app" => %{"commit" => "abcdef123456", "pipeline_id" => "87"},
        "generated_at" => "2026-07-20T12:00:00Z"
      }),
      repo: TestRepo,
      source_url: "https://example.org/static/run-old"
    )

    AdminStore.import_evidence_data!(
      Map.merge(evidence("run-current"), %{
        "app" => %{"commit" => "abcdef123456", "pipeline_id" => "88"},
        "generated_at" => "2026-07-21T12:00:00Z"
      }),
      repo: TestRepo,
      source_url: "https://example.org/static/run-current"
    )

    assert %{id: "run-current", source_url: "https://example.org/static/run-current"} =
             AdminStore.latest_run_for_deployment(
               %{"pipeline_id" => "88", "git_sha" => "abcdef123456"},
               repo: TestRepo
             )

    assert %{id: "run-old"} =
             AdminStore.latest_run_for_deployment(
               %{"pipeline_id" => "87", "git_sha" => "abcdef123456"},
               repo: TestRepo
             )

    assert %{id: "run-current"} =
             AdminStore.latest_run_for_deployment(
               %{"pipeline_id" => "missing", "git_sha" => "abcdef123456"},
               repo: TestRepo
             )

    assert is_nil(
             AdminStore.latest_run_for_deployment(
               %{"pipeline_id" => "missing", "git_sha" => "different"},
               repo: TestRepo
             )
           )
  end

  test "lists imported local run locations for evidence retention" do
    AdminStore.import_evidence_data!(
      Map.put(evidence("run-old"), "generated_at", "2026-07-20T12:00:00Z"),
      repo: TestRepo,
      source_dir: "/srv/evidence/run-old"
    )

    AdminStore.import_evidence_data!(
      Map.put(evidence("run-new"), "generated_at", "2026-07-21T12:00:00Z"),
      repo: TestRepo,
      source_dir: "/srv/evidence/run-new"
    )

    assert [new, old] = AdminStore.retention_runs(repo: TestRepo)
    assert %{id: "run-new", source_dir: "/srv/evidence/run-new"} = new
    assert %{id: "run-old", source_dir: "/srv/evidence/run-old"} = old
  end

  test "prefers a locally available screenshot over the stored source URL" do
    source_dir =
      Path.join(
        System.tmp_dir!(),
        "acceptance-harness-screenshot-#{System.unique_integer([:positive])}"
      )

    screenshot_path = Path.join([source_dir, "screenshots", "checkout-1.png"])
    File.mkdir_p!(Path.dirname(screenshot_path))
    File.write!(screenshot_path, "png")
    on_exit(fn -> File.rm_rf!(source_dir) end)

    AdminStore.import_evidence_data!(evidence("run-local"),
      repo: TestRepo,
      source_dir: source_dir,
      source_url: "https://example.org/static/run-local"
    )

    assert {:file, ^screenshot_path} =
             AdminStore.screenshot_location("run-local", "checkout-1.png", repo: TestRepo)
  end

  test "prefers the local WebP for thumbnail requests while original requests keep the PNG" do
    source_dir =
      Path.join(
        System.tmp_dir!(),
        "acceptance-harness-thumbnail-preference-#{System.unique_integer([:positive])}"
      )

    screenshot_path = Path.join([source_dir, "screenshots", "checkout-1.png"])
    thumbnail_path = Path.join([source_dir, "thumbnails", "checkout-1.webp"])
    File.mkdir_p!(Path.dirname(screenshot_path))
    File.mkdir_p!(Path.dirname(thumbnail_path))
    File.write!(screenshot_path, "png")
    File.write!(thumbnail_path, "webp")
    on_exit(fn -> File.rm_rf!(source_dir) end)

    AdminStore.import_evidence_data!(evidence("run-thumbnail-preference"),
      repo: TestRepo,
      source_dir: source_dir
    )

    assert {:file, ^thumbnail_path} =
             AdminStore.screenshot_location("run-thumbnail-preference", "checkout-1.png",
               repo: TestRepo,
               variant: :thumbnail
             )

    assert {:file, ^screenshot_path} =
             AdminStore.screenshot_location("run-thumbnail-preference", "checkout-1.png",
               repo: TestRepo
             )
  end

  test "falls back to the stored source URL when the local screenshot is unavailable" do
    AdminStore.import_evidence_data!(evidence("run-remote"),
      repo: TestRepo,
      source_dir: Path.join(System.tmp_dir!(), "missing-acceptance-evidence"),
      source_url: "https://example.org/static/run-remote"
    )

    assert {:url, "https://example.org/static/run-remote/screenshots/checkout-1.png"} =
             AdminStore.screenshot_location("run-remote", "checkout-1.png", repo: TestRepo)
  end

  test "compares domain schema artifacts with the previous trustworthy run" do
    AdminStore.import_evidence_data!(
      evidence_with_artifacts(
        "run-a",
        "2026-07-20T12:00:00Z",
        [
          schema_domain("identity", "Identity", "old"),
          schema_domain("catalogue", "Catalogue", "same")
        ]
      ),
      repo: TestRepo
    )

    AdminStore.import_evidence_data!(
      evidence_with_artifacts(
        "run-b",
        "2026-07-21T12:00:00Z",
        [
          schema_domain("identity", "Identity", "new"),
          schema_domain("catalogue", "Catalogue", "same")
        ]
      ),
      repo: TestRepo
    )

    assert %{
             previous_run_id: "run-a",
             changes: [
               %{
                 domain_id: "identity",
                 label: "Identity",
                 status: "changed",
                 current: %{"sha256" => "new"},
                 previous: %{"sha256" => "old"}
               }
             ]
           } = AdminStore.schema_history("run-b", repo: TestRepo)

    assert %{schema_domain_change_count: 1, changed_schema_domains: ["Identity"]} =
             AdminStore.list_runs(repo: TestRepo)
             |> Enum.find(&(&1.id == "run-b"))
             |> Map.take([:schema_domain_change_count, :changed_schema_domains])
  end

  test "resolves safe generic run artifacts locally and through the stored source URL" do
    source_dir =
      Path.join(
        System.tmp_dir!(),
        "acceptance-harness-artifact-#{System.unique_integer([:positive])}"
      )

    artifact_path = Path.join([source_dir, "schema", "domains", "identity.svg"])
    File.mkdir_p!(Path.dirname(artifact_path))
    File.write!(artifact_path, "<svg></svg>")
    on_exit(fn -> File.rm_rf!(source_dir) end)

    AdminStore.import_evidence_data!(evidence("run-artifact"),
      repo: TestRepo,
      source_dir: source_dir,
      source_url: "https://example.org/static/run-artifact"
    )

    assert {:file, ^artifact_path} =
             AdminStore.artifact_location(
               "run-artifact",
               "schema/domains/identity.svg",
               repo: TestRepo
             )

    assert :error =
             AdminStore.artifact_location("run-artifact", "../secret", repo: TestRepo)

    File.rm!(artifact_path)

    assert {:url, "https://example.org/static/run-artifact/schema/domains/identity.svg"} =
             AdminStore.artifact_location(
               "run-artifact",
               "schema/domains/identity.svg",
               repo: TestRepo
             )
  end

  test "serves a retained WebP thumbnail when the original screenshot was archived" do
    source_dir =
      Path.join(
        System.tmp_dir!(),
        "acceptance-harness-thumbnail-#{System.unique_integer([:positive])}"
      )

    thumbnail_path = Path.join([source_dir, "thumbnails", "checkout-1.webp"])
    File.mkdir_p!(Path.dirname(thumbnail_path))
    File.write!(thumbnail_path, "webp")
    on_exit(fn -> File.rm_rf!(source_dir) end)

    AdminStore.import_evidence_data!(evidence("run-thumbnail"),
      repo: TestRepo,
      source_dir: source_dir
    )

    assert {:file, ^thumbnail_path} =
             AdminStore.screenshot_location("run-thumbnail", "checkout-1.png", repo: TestRepo)
  end

  defp evidence_with_artifacts(run_id, generated_at, artifacts) do
    evidence(run_id)
    |> Map.put("generated_at", generated_at)
    |> Map.put("artifacts", artifacts)
  end

  defp schema_domain(id, label, hash) do
    %{
      "type" => "schema_domain",
      "domain_id" => id,
      "label" => label,
      "sha256" => hash,
      "dot_path" => "schema/domains/#{id}.dot",
      "path" => "schema/domains/#{id}.svg"
    }
  end

  test "legacy scenario ids keep renamed scenarios comparable" do
    AdminStore.import_evidence_data!(evidence("run-a"), repo: TestRepo)

    renamed =
      evidence("run-b", %{
        "id" => "participants-01-checkout",
        "metadata" => %{"legacy_ids" => ["checkout"]},
        "steps" => [
          step("run-b", "participants-01-checkout", 1, "Open checkout"),
          step("run-b", "participants-01-checkout", 2, "Pay"),
          step("run-b", "participants-01-checkout", 3, "Confirmation")
        ]
      })

    AdminStore.import_evidence_data!(renamed, repo: TestRepo)

    assert [renamed_scenario] = AdminStore.list_scenarios("run-b", repo: TestRepo)
    assert renamed_scenario.change_status == nil
    assert renamed_scenario.previous_title == "Checkout"
  end

  test "one legacy scenario id cannot belong to two current scenarios" do
    duplicated_aliases =
      evidence("run-b")
      |> Map.put("scenarios", [
        %{
          "id" => "participants-01-checkout",
          "title" => "Participant checkout",
          "status" => "success",
          "metadata" => %{"legacy_ids" => ["checkout"]},
          "steps" => []
        },
        %{
          "id" => "organizations-01-checkout",
          "title" => "Organization checkout",
          "status" => "success",
          "metadata" => %{"legacy_ids" => ["checkout"]},
          "steps" => []
        }
      ])

    assert_raise ArgumentError, ~r/legacy scenario id "checkout" is claimed by/, fn ->
      AdminStore.import_evidence_data!(duplicated_aliases, repo: TestRepo)
    end
  end

  test "scenario listing exposes evidence steps and run failure counts" do
    AdminStore.import_evidence_data!(evidence("run-a"), repo: TestRepo)

    AdminStore.import_evidence_data!(
      evidence("run-b", %{"status" => "failure"}),
      repo: TestRepo
    )

    assert [scenario] = AdminStore.list_scenarios("run-b", repo: TestRepo)

    assert Enum.map(scenario.steps, & &1["screenshot"]["name"]) ==
             ~w(checkout-1.png checkout-2.png checkout-3.png)

    assert Enum.map(scenario.steps, & &1["position"]) == [1, 2, 3]

    runs = AdminStore.list_runs(repo: TestRepo)
    assert Enum.find(runs, &(&1.id == "run-a")).failure_count == 0
    assert Enum.find(runs, &(&1.id == "run-b")).failure_count == 1
  end

  test "scenario filters cover facets and page-text search" do
    checkout = %{
      "id" => "checkout",
      "title" => "Checkout",
      "status" => "success",
      "order" => 1,
      "devices" => ["Mobile"],
      "languages" => ["Français"],
      "users" => ["facilitator"],
      "tags" => ["payments"],
      "metadata" => %{
        "value_stream" => "participants",
        "capability" => "payment",
        "business_outcome" => "Complete a paid registration"
      },
      "steps" => [
        step("run-a", "checkout", 1, "Pay", %{
          "metadata" => %{
            "scenario_id" => "checkout",
            "current_url" => "https://staging.example.org/admin/facilitators?locale=en"
          },
          "page" => %{"text" => "Votre paiement est confirmé", "html" => "<main>ok</main>"}
        })
      ]
    }

    passport = %{
      "id" => "passport",
      "title" => "Passport",
      "status" => "success",
      "order" => 2,
      "devices" => ["Desktop"],
      "languages" => ["English"],
      "users" => ["participant"],
      "tags" => ["stamps"],
      "metadata" => %{
        "value_stream" => "growth",
        "capability" => "retention",
        "business_outcome" => "Return to participation history"
      },
      "steps" => [
        step("run-a", "passport", 1, "Stamp grid", %{
          "page" => %{"text" => "Your passport is ready", "html" => "<main>grid</main>"}
        })
      ]
    }

    AdminStore.import_evidence_data!(
      %{"title" => "Evidence", "run" => %{"id" => "run-a"}, "scenarios" => [checkout, passport]},
      repo: TestRepo
    )

    list = fn opts -> AdminStore.list_scenarios("run-a", [repo: TestRepo] ++ opts) end

    assert [%{scenario_id: "checkout", tags: ["payments"]}] = list.(device: "Mobile")

    assert [%{scenario_id: "checkout", value_stream: "participants"}] =
             list.(value_stream: "participants")

    assert [%{scenario_id: "passport", capability: "retention"}] =
             list.(capability: "retention")

    assert [%{scenario_id: "passport"}] = list.(language: "English")
    assert [%{scenario_id: "checkout"}] = list.(user: "facilitator")
    assert [%{scenario_id: "passport"}] = list.(tag: "stamps")
    assert [%{scenario_id: "checkout"}] = list.(search: "paiement")
    assert [%{scenario_id: "passport"}] = list.(search: "passport ready")
    assert [%{scenario_id: "checkout"}] = list.(search: "Checkout")
    assert [%{scenario_id: "checkout"}] = list.(search: "/admin/facilitators")

    assert [%{scenario_id: "checkout", business_outcome: "Complete a paid registration"}] =
             list.(search: "paid registration")

    assert list.(search: "nonexistent-token") == []
    assert length(list.([])) == 2

    # Captured page content is stored on the step for FTS and agent use.
    result =
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "SELECT page_text, page_html FROM acceptance_harness_steps WHERE scenario_id = 'checkout'",
        []
      )

    assert [["Votre paiement est confirmé", "<main>ok</main>"]] = result.rows

    [checkout_step] = AdminStore.list_steps("run-a", "checkout", repo: TestRepo)
    assert checkout_step.page_html == "<main>ok</main>"
  end

  test "scenario listing marks new and changed scenarios against the previous run" do
    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "run" => %{"id" => "run-a", "generated_at" => "2026-07-01T10:00:00Z"},
        "scenarios" => [
          %{
            "id" => "stable",
            "title" => "Stable",
            "status" => "success",
            "order" => 1,
            "metadata" => %{"source_checksum" => "stable-source"},
            "steps" => [step("run-a", "stable", 1, "Open")]
          },
          %{
            "id" => "changed",
            "title" => "Changed",
            "status" => "success",
            "order" => 2,
            "metadata" => %{"source_checksum" => "old-source"},
            "steps" => [step("run-a", "changed", 1, "Old copy")]
          }
        ]
      },
      repo: TestRepo
    )

    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "run" => %{"id" => "run-b", "generated_at" => "2026-07-02T10:00:00Z"},
        "scenarios" => [
          %{
            "id" => "stable",
            "title" => "Stable",
            "status" => "success",
            "order" => 1,
            "metadata" => %{"source_checksum" => "stable-source"},
            "steps" => [step("run-b", "stable", 1, "Open")]
          },
          %{
            "id" => "changed",
            "title" => "Changed",
            "status" => "success",
            "order" => 2,
            "metadata" => %{"source_checksum" => "new-source"},
            "steps" => [step("run-b", "changed", 1, "New copy")]
          },
          %{
            "id" => "new",
            "title" => "New",
            "status" => "success",
            "order" => 3,
            "steps" => [step("run-b", "new", 1, "First")]
          }
        ]
      },
      repo: TestRepo
    )

    statuses =
      "run-b"
      |> AdminStore.list_scenarios(repo: TestRepo)
      |> Map.new(&{&1.scenario_id, &1.change_status})

    assert statuses == %{"stable" => nil, "changed" => "delta", "new" => "new"}

    assert AdminStore.scenario_change_details("run-b", "changed", repo: TestRepo) == %{
             previous_run_id: "run-a",
             previous_scenario_id: "changed",
             previous_title: "Changed",
             source_file: nil,
             current_source_snapshot_path: nil,
             previous_source_snapshot_path: nil
           }

    assert AdminStore.scenario_change_details("run-b", "new", repo: TestRepo) == %{
             previous_run_id: "run-a",
             previous_scenario_id: nil,
             previous_title: nil,
             source_file: nil,
             current_source_snapshot_path: nil,
             previous_source_snapshot_path: nil
           }
  end

  test "scenario listing falls back to the recorded step contract for legacy runs" do
    import_legacy_step_comparison_run!("run-a", "2026-07-01T10:00:00Z", "Old invitation", 1)
    import_legacy_step_comparison_run!("run-b", "2026-07-02T10:00:00Z", "New invitation", 2)

    statuses =
      "run-b"
      |> AdminStore.list_scenarios(repo: TestRepo)
      |> Map.new(&{&1.scenario_id, &1.change_status})

    assert statuses == %{"changed" => "delta", "stable" => nil}
    assert AdminStore.scenario_change_status("run-b", "changed", repo: TestRepo) == "delta"
    assert AdminStore.scenario_change_status("run-b", "stable", repo: TestRepo) == nil
  end

  test "scenario listing compares step contracts across source metadata adoption" do
    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "run" => %{"id" => "run-a", "generated_at" => "2026-07-01T10:00:00Z"},
        "scenarios" => [
          %{
            "id" => "stable",
            "title" => "Stable",
            "status" => "success",
            "order" => 1,
            "steps" => [step("run-a", "stable", 1, "Open invitation")]
          }
        ]
      },
      repo: TestRepo
    )

    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "run" => %{"id" => "run-b", "generated_at" => "2026-07-02T10:00:00Z"},
        "scenarios" => [
          %{
            "id" => "stable",
            "title" => "Stable",
            "status" => "success",
            "order" => 1,
            "metadata" => %{"source_checksum" => "new-source-metadata"},
            "steps" => [step("run-b", "stable", 1, "Open invitation")]
          }
        ]
      },
      repo: TestRepo
    )

    assert [%{scenario_id: "stable", change_status: nil}] =
             AdminStore.list_scenarios("run-b", repo: TestRepo)

    assert AdminStore.scenario_change_status("run-b", "stable", repo: TestRepo) == nil
  end

  test "step listing marks semantic changes and additions without step checksums" do
    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "run" => %{"id" => "run-a", "generated_at" => "2026-07-01T10:00:00Z"},
        "scenarios" => [
          %{
            "id" => "checkout",
            "title" => "Checkout",
            "status" => "success",
            "order" => 1,
            "steps" => [
              step("run-a", "checkout", 1, "Open checkout"),
              step("run-a", "checkout", 2, "Pay")
            ]
          }
        ]
      },
      repo: TestRepo
    )

    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "run" => %{"id" => "run-b", "generated_at" => "2026-07-02T10:00:00Z"},
        "scenarios" => [
          %{
            "id" => "checkout",
            "title" => "Checkout",
            "status" => "success",
            "order" => 1,
            "steps" => [
              step("run-b", "checkout", 1, "Open checkout"),
              step("run-b", "checkout", 2, "Pay", %{"description" => "Confirm payment"}),
              step("run-b", "checkout", 3, "Read confirmation")
            ]
          }
        ]
      },
      repo: TestRepo
    )

    assert [
             %{title: "Open checkout", change_status: nil},
             %{
               title: "Pay",
               change_status: "delta",
               previous_title: "Pay",
               previous_description: "Pay description",
               previous_position: 2
             },
             %{
               title: "Read confirmation",
               change_status: "new",
               previous_title: nil,
               previous_description: nil,
               previous_position: nil
             }
           ] = AdminStore.list_steps("run-b", "checkout", repo: TestRepo)

    assert [%{new_step_count: 1, delta_step_count: 1}] =
             AdminStore.list_runs(repo: TestRepo, limit: 1)
  end

  test "a run marks recovered when it passes after the previous run failed" do
    pass = fn id, status ->
      %{
        "title" => "Evidence",
        "run" => %{"id" => id, "generated_at" => "2026-07-0#{String.last(id)}T10:00:00Z"},
        "scenarios" => [
          %{
            "id" => "checkout",
            "title" => "Checkout",
            "status" => status,
            "order" => 1,
            "steps" => [step(id, "checkout", 1, "Open checkout")]
          }
        ]
      }
    end

    AdminStore.import_evidence_data!(pass.("run-1", "success"), repo: TestRepo)
    AdminStore.import_evidence_data!(pass.("run-2", "failure"), repo: TestRepo)
    AdminStore.import_evidence_data!(pass.("run-3", "success"), repo: TestRepo)

    runs = Map.new(AdminStore.list_runs(repo: TestRepo), &{&1.id, &1})

    # run-3 passed right after run-2 failed: recovered.
    assert runs["run-3"].failure_count == 0
    assert runs["run-3"].recovered
    # run-2 is itself failing, not a recovery.
    refute runs["run-2"].recovered
    # run-1 passed after nothing before it.
    refute runs["run-1"].recovered
  end

  test "a failed partial run does not make the next identical run look new" do
    full_scenario = fn run_id ->
      %{
        "id" => "checkout",
        "title" => "Checkout",
        "status" => "success",
        "order" => 1,
        "steps" => [
          step(run_id, "checkout", 1, "Open checkout"),
          step(run_id, "checkout", 2, "Pay"),
          step(run_id, "checkout", 3, "Read confirmation")
        ]
      }
    end

    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "run" => %{"id" => "run-good", "generated_at" => "2026-07-01T10:00:00Z"},
        "scenarios" => [full_scenario.("run-good")]
      },
      repo: TestRepo
    )

    # The run in between failed early, so it only captured the first step.
    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "run" => %{"id" => "run-failed", "generated_at" => "2026-07-02T10:00:00Z"},
        "scenarios" => [
          %{
            "id" => "checkout",
            "title" => "Checkout",
            "status" => "failure",
            "order" => 1,
            "steps" => [step("run-failed", "checkout", 1, "Open checkout")]
          }
        ]
      },
      repo: TestRepo
    )

    # Re-running the very same suite changed nothing, so the card must stay
    # grey instead of announcing the steps the failed run never reached.
    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "run" => %{"id" => "run-retry", "generated_at" => "2026-07-03T10:00:00Z"},
        "scenarios" => [full_scenario.("run-retry")]
      },
      repo: TestRepo
    )

    assert [%{new_step_count: 0, delta_step_count: 0, new_scenario_count: 0}] =
             AdminStore.list_runs(repo: TestRepo, limit: 1)
  end

  test "run listing marks recorded contract changes without source checksums" do
    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "run" => %{"id" => "run-a", "generated_at" => "2026-07-01T10:00:00Z"},
        "scenarios" => [
          %{
            "id" => "changed",
            "title" => "Changed",
            "status" => "success",
            "order" => 1,
            "steps" => [step("run-a", "changed", 1, "Old copy")]
          }
        ]
      },
      repo: TestRepo
    )

    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "run" => %{"id" => "run-b", "generated_at" => "2026-07-02T10:00:00Z"},
        "scenarios" => [
          %{
            "id" => "changed",
            "title" => "Changed",
            "status" => "failure",
            "order" => 1,
            "steps" => [step("run-b", "changed", 1, "New browser copy")]
          }
        ]
      },
      repo: TestRepo
    )

    assert [%{scenario_id: "changed", change_status: "delta"}] =
             AdminStore.list_scenarios("run-b", repo: TestRepo)
  end

  test "run listing breaks down source changes" do
    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "generated_at" => "2099-07-01T10:00:00Z",
        "run" => %{"id" => "run-a", "generated_at" => "2026-07-01T10:00:00Z"},
        "scenarios" => [
          %{
            "id" => "stable",
            "title" => "Stable",
            "status" => "success",
            "order" => 1,
            "metadata" => %{"source_checksum" => "stable-source"},
            "steps" => [step("run-a", "stable", 1, "Open")]
          },
          %{
            "id" => "changed",
            "title" => "Changed",
            "status" => "success",
            "order" => 2,
            "metadata" => %{"source_checksum" => "old-source"},
            "steps" => [step("run-a", "changed", 1, "Old copy")]
          }
        ]
      },
      repo: TestRepo
    )

    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "generated_at" => "2099-07-02T10:00:00Z",
        "run" => %{"id" => "run-b", "generated_at" => "2099-07-02T10:00:00Z"},
        "scenarios" => [
          %{
            "id" => "stable",
            "title" => "Stable",
            "status" => "success",
            "order" => 1,
            "metadata" => %{"source_checksum" => "stable-source"},
            "steps" => [step("run-b", "stable", 1, "Open")]
          },
          %{
            "id" => "changed",
            "title" => "Changed",
            "status" => "success",
            "order" => 2,
            "metadata" => %{"source_checksum" => "new-source"},
            "steps" => [step("run-b", "changed", 1, "New copy")]
          },
          %{
            "id" => "new",
            "title" => "New",
            "status" => "success",
            "order" => 3,
            "steps" => [step("run-b", "new", 1, "First")]
          }
        ]
      },
      repo: TestRepo
    )

    assert [latest | _] = AdminStore.list_runs(repo: TestRepo)
    assert latest.id == "run-b"
    assert latest.new_scenario_count == 1
    assert latest.delta_scenario_count == 1

    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "generated_at" => "2099-07-03T10:00:00Z",
        "run" => %{"id" => "run-c", "generated_at" => "2100-07-03T10:00:00Z"},
        "scenarios" => [
          %{
            "id" => "stable",
            "title" => "Stable",
            "status" => "success",
            "order" => 1,
            "metadata" => %{"source_checksum" => "stable-source"},
            "steps" => [step("run-c", "stable", 1, "Open")]
          },
          %{
            "id" => "changed",
            "title" => "Changed",
            "status" => "success",
            "order" => 2,
            "metadata" => %{"source_checksum" => "new-source"},
            "steps" => [step("run-c", "changed", 1, "New browser copy")]
          },
          %{
            "id" => "new",
            "title" => "New",
            "status" => "success",
            "order" => 3,
            "steps" => [step("run-c", "new", 1, "First")]
          }
        ]
      },
      repo: TestRepo
    )

    [next | _] = AdminStore.list_runs(repo: TestRepo)
    assert next.id == "run-c"
  end

  test "install! removes the retired work-status table" do
    Ecto.Adapters.SQL.query!(TestRepo, """
    CREATE TABLE acceptance_harness_statuses (
      id bigserial PRIMARY KEY,
      scenario_key text NOT NULL,
      step_sequence bigint NOT NULL DEFAULT 0,
      status text NOT NULL DEFAULT 'triage'
    )
    """)

    AdminStore.install!(repo: TestRepo)

    assert [[nil]] =
             Ecto.Adapters.SQL.query!(
               TestRepo,
               "SELECT to_regclass('acceptance_harness_statuses')",
               []
             ).rows
  end

  test "install! repairs double-encoded jsonb rows written by v0.3.x" do
    AdminStore.import_evidence_data!(evidence("run-a"), repo: TestRepo)

    Ecto.Adapters.SQL.query!(
      TestRepo,
      "UPDATE acceptance_harness_scenarios SET devices = to_jsonb('[\"Mobile\"]'::text)",
      []
    )

    assert AdminStore.list_scenarios("run-a", device: "Mobile", repo: TestRepo) == []

    AdminStore.install!(repo: TestRepo)

    assert [%{devices: ["Mobile"]}] =
             AdminStore.list_scenarios("run-a", device: "Mobile", repo: TestRepo)
  end

  test "install! preserves legacy plain strings in jsonb columns" do
    AdminStore.import_evidence_data!(evidence("run-a"), repo: TestRepo)

    Ecto.Adapters.SQL.query!(
      TestRepo,
      "UPDATE acceptance_harness_steps SET surface = to_jsonb('LiveView desktop'::text)",
      []
    )

    AdminStore.install!(repo: TestRepo)

    rows =
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "SELECT surface FROM acceptance_harness_steps",
        []
      ).rows

    assert rows != []
    assert Enum.all?(rows, &(&1 == ["LiveView desktop"]))
  end

  test "imports and returns a scenario's failure diagnostics" do
    failure = %{
      "message" => "Could not find element \"[data-gap]\"",
      "code" => "assert_has(conn, \"[data-gap]\")",
      "location" => "test/example_test.exs:12",
      "screenshots" => ["s5-01.png"]
    }

    AdminStore.import_evidence_data!(
      evidence("run-a", %{"status" => "failure", "failure" => failure}),
      repo: TestRepo
    )

    scenario = AdminStore.get_scenario!("run-a", "checkout", repo: TestRepo)
    assert scenario["failure"]["message"] == "Could not find element \"[data-gap]\""
    assert scenario["failure"]["screenshots"] == ["s5-01.png"]

    # Re-importing a green run clears the failure.
    AdminStore.import_evidence_data!(evidence("run-a"), repo: TestRepo)
    assert AdminStore.get_scenario!("run-a", "checkout", repo: TestRepo)["failure"] == nil
  end
end
