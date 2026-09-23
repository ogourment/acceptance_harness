defmodule Mix.Tasks.Acceptance.ReviewCoverage do
  @shortdoc "Report human review gaps for an imported release run (advisory)"
  use Mix.Task
  alias AcceptanceHarness.{AdminStore, ReviewStore, ReviewTarget}

  def run([run_id]) do
    Mix.Task.run("app.start")

    rows =
      for scenario <- AdminStore.list_scenarios(run_id) do
        target = ReviewTarget.resolve(run_id, scenario.scenario_id)
        summary = ReviewStore.summary(target.project, target.target, target.revision)

        steps =
          for step <- AdminStore.list_steps(run_id, scenario.scenario_id) do
            step_target = ReviewTarget.resolve(run_id, scenario.scenario_id, step.id)

            stats =
              ReviewStore.summary(step_target.project, step_target.target, step_target.revision)

            %{id: step.id, state: stats.state, reads: stats.reads}
          end

        %{
          scenario: scenario.scenario_id,
          scenario_reads: summary.reads,
          current_steps_viewed: Enum.count(steps, &(&1.reads > 0)),
          required_steps: length(steps),
          complete: steps != [] and Enum.all?(steps, &(&1.reads > 0)),
          steps: steps
        }
      end

    Mix.shell().info(
      Jason.encode!(
        %{
          run: run_id,
          policy: "advisory",
          tracking_history: "unknown before instrumentation",
          scenarios: rows
        },
        pretty: true
      )
    )
  end

  def run(_), do: Mix.raise("Usage: mix acceptance.review_coverage RUN_ID")
end
