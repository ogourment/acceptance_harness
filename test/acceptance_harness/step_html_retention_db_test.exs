defmodule AcceptanceHarness.StepHtmlRetentionDbTest do
  @moduledoc """
  Raw per-step HTML dominates the evidence schema and, because the whole
  database is dumped hourly, it dominates backup size too. These tests pin the
  retention behaviour and — more importantly — everything it must leave alone.
  """
  use ExUnit.Case, async: false

  @moduletag :db

  alias AcceptanceHarness.AdminStore
  alias AcceptanceHarness.TestRepo

  setup do
    AdminStore.install!(repo: TestRepo)

    Ecto.Adapters.SQL.query!(
      TestRepo,
      "TRUNCATE acceptance_harness_runs CASCADE",
      []
    )

    :ok
  end

  defp evidence(run_id) do
    sequence = System.unique_integer([:positive, :monotonic])

    %{
      "title" => "Evidence",
      "run" => %{"id" => run_id},
      "scenarios" => [
        %{
          "id" => "checkout",
          "title" => "Checkout",
          "status" => "success",
          "order" => 1,
          "steps" => [
            %{
              "id" => "checkout-1-#{run_id}-#{sequence}",
              "scenario_id" => "checkout",
              "title" => "Open checkout",
              "description" => "Open checkout description",
              "sequence" => sequence,
              "screenshot" => %{"name" => "checkout-1.png"},
              "metadata" => %{
                "scenario_id" => "checkout",
                "page_text" => "Visible page copy for #{run_id}",
                "page_html" => "<html><body>heavy #{run_id}</body></html>"
              }
            }
          ]
        }
      ]
    }
  end

  defp age_run!(run_id, days) do
    Ecto.Adapters.SQL.query!(
      TestRepo,
      """
      UPDATE acceptance_harness_runs
      SET finalized_at = now() - ($2 || ' days')::interval,
          generated_at = now() - ($2 || ' days')::interval,
          inserted_at  = now() - ($2 || ' days')::interval
      WHERE id = $1
      """,
      [run_id, to_string(days)]
    )
  end

  defp html_for(run_id) do
    %{rows: [[html]]} =
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "SELECT page_html FROM acceptance_harness_steps WHERE run_id = $1 LIMIT 1",
        [run_id]
      )

    html
  end

  defp text_for(run_id) do
    %{rows: [[text]]} =
      Ecto.Adapters.SQL.query!(
        TestRepo,
        "SELECT page_text FROM acceptance_harness_steps WHERE run_id = $1 LIMIT 1",
        [run_id]
      )

    text
  end

  test "clears page_html beyond the window and keeps it inside" do
    AdminStore.import_evidence_data!(evidence("run-old"), repo: TestRepo)
    AdminStore.import_evidence_data!(evidence("run-recent"), repo: TestRepo)
    age_run!("run-old", 30)
    age_run!("run-recent", 2)

    assert html_for("run-old")
    assert html_for("run-recent")

    summary = AdminStore.prune_step_html!(repo: TestRepo, keep_days: 7)

    assert summary.runs == 1
    assert summary.steps == 1
    assert summary.bytes_reclaimed > 0
    assert is_nil(html_for("run-old"))
    assert html_for("run-recent")
  end

  test "keeps page_text so evidence stays searchable" do
    AdminStore.import_evidence_data!(evidence("run-old"), repo: TestRepo)
    age_run!("run-old", 30)

    AdminStore.prune_step_html!(repo: TestRepo, keep_days: 7)

    assert is_nil(html_for("run-old"))
    assert text_for("run-old") == "Visible page copy for run-old"
  end

  test "keeps runs, scenarios, steps and screenshots" do
    AdminStore.import_evidence_data!(evidence("run-old"), repo: TestRepo)
    age_run!("run-old", 30)

    AdminStore.prune_step_html!(repo: TestRepo, keep_days: 7)

    assert [step] = AdminStore.list_steps("run-old", "checkout", repo: TestRepo)
    assert step.title == "Open checkout"
    assert step.screenshot != %{}
    assert [_scenario] = AdminStore.list_scenarios("run-old", repo: TestRepo)
  end

  test "dry_run reports without writing" do
    AdminStore.import_evidence_data!(evidence("run-old"), repo: TestRepo)
    age_run!("run-old", 30)

    summary = AdminStore.prune_step_html!(repo: TestRepo, keep_days: 7, dry_run: true)

    assert summary.dry_run?
    assert summary.steps == 1
    assert html_for("run-old"), "dry run must not clear page_html"
  end

  test "is idempotent" do
    AdminStore.import_evidence_data!(evidence("run-old"), repo: TestRepo)
    age_run!("run-old", 30)

    first = AdminStore.prune_step_html!(repo: TestRepo, keep_days: 7)
    second = AdminStore.prune_step_html!(repo: TestRepo, keep_days: 7)

    assert first.steps == 1
    assert second.steps == 0
    assert second.bytes_reclaimed == 0
  end

  test "clears every stale run, not just one" do
    # The first implementation used a single UPDATE across all stale rows. That
    # exceeded the query timeout against production-sized data, so the sweep is
    # per-run now; this pins that every stale run is still covered.
    for id <- ["run-a", "run-b", "run-c"] do
      AdminStore.import_evidence_data!(evidence(id), repo: TestRepo)
      age_run!(id, 30)
    end

    AdminStore.import_evidence_data!(evidence("run-fresh"), repo: TestRepo)
    age_run!("run-fresh", 1)

    summary = AdminStore.prune_step_html!(repo: TestRepo, keep_days: 7)

    assert summary.runs == 3
    assert summary.steps == 3

    for id <- ["run-a", "run-b", "run-c"] do
      assert is_nil(html_for(id)), "#{id} should have been cleared"
    end

    assert html_for("run-fresh")
  end

  test "accepts an explicit batch timeout" do
    AdminStore.import_evidence_data!(evidence("run-old"), repo: TestRepo)
    age_run!("run-old", 30)

    AdminStore.prune_step_html!(repo: TestRepo, keep_days: 7, batch_timeout: 60_000)

    assert is_nil(html_for("run-old"))
  end

  test "rejects a nonsensical window rather than deleting everything" do
    assert_raise ArgumentError, fn ->
      AdminStore.prune_step_html!(repo: TestRepo, keep_days: -1)
    end
  end
end
