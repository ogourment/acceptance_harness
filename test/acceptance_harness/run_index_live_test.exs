defmodule AcceptanceHarnessWeb.RunIndexLiveTest do
  use ExUnit.Case, async: false

  import Phoenix.LiveViewTest

  alias AcceptanceHarnessWeb.RunIndexLive

  defmodule TestActions do
    def clean(target) do
      send(target, :cleaned)
      {:ok, "cleaned"}
    end

    def fail(_target) do
      {:error, "could not clean"}
    end

    def boom(_target) do
      raise "kaboom"
    end
  end

  defp put_admin_actions(actions) do
    original = Application.get_env(:acceptance_harness, :harness, [])

    Application.put_env(
      :acceptance_harness,
      :harness,
      Keyword.put(original, :admin_actions, actions)
    )

    on_exit(fn -> Application.put_env(:acceptance_harness, :harness, original) end)
  end

  defp run_fixture(overrides) do
    Map.merge(
      %{
        id: "run-x",
        title: "A run",
        app: %{"name" => "Agile-U", "commit" => "1234567890abcdef"},
        finalized_at: ~U[2026-07-23 12:00:00Z],
        generated_at: nil,
        scenario_count: 10,
        failure_count: 0,
        new_scenario_count: 0,
        delta_scenario_count: 0,
        new_step_count: 0,
        delta_step_count: 0
      },
      overrides
    )
  end

  defp render_runs(runs) do
    RunIndexLive.render(%{
      runs: runs,
      error: nil,
      root_path: "/admin/acceptance",
      versions_path: nil
    })
    |> rendered_to_string()
  end

  test "identifies each run by its released version, not only its commit" do
    html =
      render_runs([
        run_fixture(%{
          id: "r",
          app: %{"name" => "Punnles", "version" => "0.3.7", "commit" => "1234567890abcdef"}
        })
      ])

    assert html =~ "v0.3.7"
    assert html =~ "1234567890ab"
  end

  test "omits the version rather than showing a placeholder when a run recorded none" do
    html = render_runs([run_fixture(%{id: "r", app: %{"name" => "Punnles", "commit" => "abc"}})])

    refute html =~ "v0.3.7"
    refute html =~ "vunknown"
    assert html =~ "Punnles"
  end

  test "a recovered run shows the recovered pill by the failures count" do
    html = render_runs([run_fixture(%{id: "r", recovered: true})])

    assert html =~ ~s(class="acceptance-recovered-pill")
    assert html =~ ~s(title="Passed after the previous run failed")
  end

  test "a plain passing run shows no recovered pill" do
    html = render_runs([run_fixture(%{id: "r", recovered: false})])

    refute html =~ ~s(class="acceptance-recovered-pill")
  end

  test "summarizes only changed schema domains on the run card" do
    html =
      render_runs([
        run_fixture(%{
          id: "schema-run",
          schema_domain_change_count: 2,
          changed_schema_domains: ["Identity and organisations", "Operations and evidence"],
          changed_schema_domain_refs: [
            %{id: "identity", label: "Identity and organisations"},
            %{id: "operations", label: "Operations and evidence"}
          ]
        })
      ])

    assert html =~ "<dt>Schema domains</dt>"
    assert html =~ "<dd>2</dd>"
    assert html =~ "2 domain schemas"

    # Each domain links straight to its own comparison, rather than being
    # printed as a bare list the reviewer cannot act on.
    assert html =~ "#schema-domain-identity"
    assert html =~ "#schema-domain-operations"
    assert html =~ "Identity and organisations"
    assert html =~ "Operations and evidence"
    assert html =~ ~s(id="run-schema-run-change-details")
    assert card_classes_by_title(html)["A run"] =~ "is-delta"
  end

  test "renders no maintenance section when no admin_actions are configured" do
    put_admin_actions([])

    {:ok, socket} = RunIndexLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

    html = RunIndexLive.render(socket.assigns) |> rendered_to_string()

    refute html =~ "aria-label=\"Maintenance actions\""
    refute html =~ "acceptance-action-"
  end

  test "renders configured maintenance buttons with ids and data-confirm" do
    put_admin_actions([
      %{
        id: "remove-test-data",
        label: "Remove test data",
        description: "Deletes seeded fixtures from the database.",
        run: {TestActions, :clean, [self()]}
      },
      %{
        id: "relaunch-atdd",
        label: "Relaunch ATDD",
        confirm: "Re-run the full ATDD suite?",
        run: {TestActions, :clean, [self()]}
      }
    ])

    {:ok, socket} = RunIndexLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

    html = RunIndexLive.render(socket.assigns) |> rendered_to_string()

    assert html =~ "aria-label=\"Maintenance actions\""
    assert html =~ ~s(id="acceptance-action-remove-test-data")
    assert html =~ "Remove test data"
    # The description is a tooltip now, so the header stays compact.
    assert html =~ ~s(title="Deletes seeded fixtures from the database.")
    assert html =~ ~s(id="acceptance-action-relaunch-atdd")
    assert html =~ "Relaunch ATDD"
    assert html =~ ~s(data-confirm="Re-run the full ATDD suite?")
    refute html =~ ~s(data-confirm="")
  end

  @tag :db
  test "clicking a maintenance action runs its MFA, reloads runs, and surfaces the success message" do
    AcceptanceHarness.AdminStore.install!(repo: AcceptanceHarness.TestRepo)

    original = Application.get_env(:acceptance_harness, :harness, [])

    Application.put_env(
      :acceptance_harness,
      :harness,
      Keyword.merge(original,
        repo: AcceptanceHarness.TestRepo,
        admin_actions: [
          %{
            id: "remove-test-data",
            label: "Remove test data",
            run: {TestActions, :clean, [self()]}
          }
        ]
      )
    )

    on_exit(fn -> Application.put_env(:acceptance_harness, :harness, original) end)

    {:ok, socket} = RunIndexLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      RunIndexLive.handle_event("run_admin_action", %{"id" => "remove-test-data"}, socket)

    assert_received :cleaned
    assert socket.assigns.info == "cleaned"
    assert socket.assigns.error == nil
    assert is_list(socket.assigns.runs)
  end

  test "surfaces the error message when an admin action returns {:error, message}" do
    put_admin_actions([
      %{id: "fail-action", label: "Fail action", run: {TestActions, :fail, [self()]}}
    ])

    {:ok, socket} = RunIndexLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      RunIndexLive.handle_event("run_admin_action", %{"id" => "fail-action"}, socket)

    assert socket.assigns.error == "could not clean"
    assert socket.assigns.info == nil
  end

  test "surfaces a generic failure message when an admin action raises" do
    put_admin_actions([
      %{id: "boom-action", label: "Boom action", run: {TestActions, :boom, [self()]}}
    ])

    {:ok, socket} = RunIndexLive.mount(%{}, %{}, %Phoenix.LiveView.Socket{})

    {:noreply, socket} =
      RunIndexLive.handle_event("run_admin_action", %{"id" => "boom-action"}, socket)

    assert socket.assigns.error == "Action failed: kaboom"
    assert socket.assigns.info == nil
  end

  test "renders evidence-change summaries" do
    html =
      RunIndexLive.render(%{
        runs: [
          %{
            id: "run-1",
            title: "Current run",
            app: %{"name" => "Ecojeux", "commit" => "1234567890abcdef"},
            finalized_at: ~U[2026-07-11 12:00:00Z],
            generated_at: nil,
            scenario_count: 9,
            failure_count: 1,
            new_scenario_count: 2,
            delta_scenario_count: 3,
            new_step_count: 1,
            delta_step_count: 2,
            changed_scenarios: [
              %{scenario_id: "new-account", title: "Create an account", status: "new"},
              %{scenario_id: "checkout", title: "Complete checkout", status: "delta"}
            ]
          },
          %{
            id: "run-2",
            title: "Previous run",
            app: %{"name" => "Ecojeux", "commit" => "abcdef1234567890"},
            finalized_at: ~U[2026-07-11 11:00:00Z],
            generated_at: nil,
            scenario_count: 9,
            failure_count: 0,
            new_scenario_count: 0,
            delta_scenario_count: 0,
            new_step_count: 0,
            delta_step_count: 0
          }
        ],
        error: nil,
        root_path: "/admin/acceptance",
        versions_path: "/admin/versions"
      })
      |> rendered_to_string()

    refute html =~ "acceptance-change-breakdown"
    assert html =~ "Failures"
    assert html =~ ~r/<dt>Failures<\/dt>\s*<div class="acceptance-stat-value-row">\s*<dd>1<\/dd>/
    assert html =~ "acceptance-stat-value-row"
    assert html =~ "aria-label=\"Scenario source changes\""
    assert html =~ "acceptance-change-icon"
    assert html =~ ~s(id="run-run-1-change-details")
    assert html =~ "Run changes"
    assert html =~ "What changed?"
    assert html =~ "2 new scenarios"
    assert html =~ "3 changed scenarios"
    assert html =~ "1 new recorded step"
    assert html =~ "2 changed recorded steps"
    refute html =~ "Open the run to review changed scenarios and steps."
    assert html =~ ~s(href="/admin/acceptance/runs/run-1/scenarios/new-account")
    assert html =~ "Create an account"
    assert html =~ ~s(href="/admin/acceptance/runs/run-1/scenarios/checkout")
    assert html =~ "Complete checkout"
    refute html =~ ~s(id="run-run-2-change-details")

    assert html =~
             "acceptance_harness v#{to_string(Application.spec(:acceptance_harness, :vsn) || "dev")}"

    assert html =~ ~s(href="/admin/versions")
    assert html =~ "Deployment versions"

    assert card_classes_by_title(html)["Current run"] =~ "is-failure"
    assert card_classes_by_title(html)["Previous run"] =~ "is-unknown"
  end

  test "colors runs by failure, new, changed, then unchanged precedence" do
    runs =
      for {id, failure_count, new_scenarios, new_steps, delta_scenarios, delta_steps} <- [
            {"failed", 1, 1, 1, 1, 1},
            {"new", 0, 0, 1, 1, 0},
            {"changed", 0, 0, 0, 0, 1},
            {"unchanged", 0, 0, 0, 0, 0}
          ] do
        %{
          id: id,
          title: id,
          app: %{"name" => "Ecojeux", "commit" => "1234567890abcdef"},
          finalized_at: ~U[2026-07-11 12:00:00Z],
          generated_at: nil,
          scenario_count: 1,
          failure_count: failure_count,
          new_scenario_count: new_scenarios,
          delta_scenario_count: delta_scenarios,
          new_step_count: new_steps,
          delta_step_count: delta_steps
        }
      end

    html =
      RunIndexLive.render(%{
        runs: runs,
        error: nil,
        root_path: "/admin/acceptance",
        versions_path: nil
      })
      |> rendered_to_string()

    classes = card_classes_by_title(html)

    assert classes["failed"] =~ "is-failure"
    assert classes["new"] =~ "is-new"
    assert classes["changed"] =~ "is-delta"
    assert classes["unchanged"] =~ "is-unknown"
  end

  defp card_classes_by_title(html) do
    html
    |> then(
      &Regex.scan(~r/<article class="([^"]*acceptance-run-card[^"]*)">(.+?)<\/article>/s, &1)
    )
    |> Map.new(fn [_card, classes, body] ->
      [_, title] = Regex.run(~r/<h2>\s*<a[^>]*>([^<]*)<\/a>/s, body)
      {title, classes}
    end)
  end
end
