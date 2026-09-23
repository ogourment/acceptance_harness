defmodule AcceptanceHarness.ReviewTarget do
  @moduledoc false
  alias AcceptanceHarness.{AdminStore, ReviewReceipt}

  # Resolve targets from trusted retained evidence, never from a client's claimed
  # project or fingerprint. Stable review_id is recommended for step producers.
  def resolve(run_id, scenario_id \\ nil, step_id \\ nil) do
    run = AdminStore.get_run!(run_id)
    project = run["app"]["name"] || AcceptanceHarness.Config.app_name()

    cond do
      step_id != nil ->
        step =
          Enum.find(AdminStore.list_steps(run_id, scenario_id), &(&1.id == step_id)) ||
            raise ArgumentError, "unknown step"

        stable = step.metadata["review_id"] || step.screenshot["name"] || step.id

        %{
          project: project,
          target: "step/#{scenario_id}/#{stable}",
          revision: ReviewReceipt.fingerprint(step_content(run_id, step)),
          run_id: run_id
        }

      scenario_id != nil ->
        scenario = AdminStore.get_scenario!(run_id, scenario_id)
        steps = AdminStore.list_steps(run_id, scenario_id)

        %{
          project: project,
          target: "scenario/#{scenario_id}",
          revision:
            ReviewReceipt.fingerprint([
              scenario["title"],
              Enum.map(steps, &step_content(run_id, &1))
            ]),
          run_id: run_id
        }

      true ->
        %{
          project: project,
          target: "run/#{run["app"]["commit"] || run_id}",
          revision: ReviewReceipt.fingerprint([run["app"]["commit"], run["title"]]),
          run_id: run_id
        }
    end
  end

  defp step_content(run_id, step) do
    image =
      case step.screenshot["name"] do
        name when is_binary(name) ->
          case AdminStore.screenshot_path(run_id, name) do
            {:ok, path} ->
              case File.read(path) do
                {:ok, bytes} -> Base.encode16(:crypto.hash(:sha256, bytes))
                _ -> ["unavailable", run_id]
              end

            _ ->
              ["unavailable", run_id]
          end

        _ ->
          nil
      end

    [
      step.title,
      step.description,
      step.page_html,
      step.surface,
      image,
      step.metadata["source_checksum"],
      step.metadata["source_sha256"]
    ]
  end
end
