defmodule AcceptanceHarnessWeb.ReviewActivityController do
  @moduledoc false
  use Phoenix.Controller, formats: [:json]
  alias AcceptanceHarness.{ReviewReceipt, ReviewStore, ReviewTarget}

  def show(conn, %{"run_id" => run_id} = params) do
    target = ReviewTarget.resolve(run_id, params["scenario_id"], params["step_id"])
    json(conn, ReviewStore.summary(target.project, target.target, target.revision))
  rescue
    _ -> conn |> put_status(503) |> json(%{error: "Review tracking incomplete"})
  end

  def show(conn, _), do: conn |> put_status(422) |> json(%{error: "Invalid review target"})

  def create(conn, %{"run_id" => run_id, "session" => session} = params)
      when is_binary(session) and byte_size(session) in 16..128 do
    target = ReviewTarget.resolve(run_id, params["scenario_id"], params["step_id"])

    source =
      if params["source"] in ["human", "automated"], do: params["source"], else: "unattributed"

    env =
      Application.get_env(:acceptance_harness, :harness, [])
      |> Keyword.get(:review_environment, "unknown")

    attrs = %{
      "project" => target.project,
      "target" => target.target,
      "revision" => target.revision,
      "run_id" => run_id,
      "environment" => to_string(env),
      "source" => source,
      "viewed_at" => DateTime.to_iso8601(DateTime.utc_now())
    }

    with {:ok, receipt} <- ReviewReceipt.new(attrs, session),
         {:ok, _} <- ReviewStore.import!(target.project, [receipt]) do
      json(conn, ReviewStore.summary(target.project, target.target, target.revision))
    else
      _ -> conn |> put_status(503) |> json(%{error: "Review tracking incomplete"})
    end
  rescue
    _ -> conn |> put_status(503) |> json(%{error: "Review tracking incomplete"})
  end

  def create(conn, _), do: conn |> put_status(422) |> json(%{error: "Invalid review event"})
end
