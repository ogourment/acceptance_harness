defmodule AcceptanceHarnessWeb.Router do
  @moduledoc """
  Router helpers for mounting the acceptance admin add-on.

  Host applications should call `acceptance_harness/1` inside an authenticated
  admin scope.
  """

  defmacro acceptance_harness(path, opts \\ []) do
    live? = Keyword.get(opts, :live, true)
    controllers? = Keyword.get(opts, :controllers, true)

    quote bind_quoted: [path: path, live?: live?, controllers?: controllers?] do
      scope path, alias: false, as: :acceptance_harness do
        if live? do
          live("/", AcceptanceHarnessWeb.RunIndexLive, :index)
          live("/runs/:run_id", AcceptanceHarnessWeb.RunLive, :show)
          live("/runs/:run_id/scenarios/:scenario_id", AcceptanceHarnessWeb.ScenarioLive, :show)
        end

        if controllers? do
          post("/review-activity", AcceptanceHarnessWeb.ReviewActivityController, :create)
          get("/review-activity", AcceptanceHarnessWeb.ReviewActivityController, :show)
          get("/latest", AcceptanceHarnessWeb.LatestController, :show)
          get("/screenshots/:run_id/:filename", AcceptanceHarnessWeb.ScreenshotController, :show)
          get("/artifacts/:run_id/*path", AcceptanceHarnessWeb.ArtifactController, :show)
        end
      end
    end
  end

  @doc """
  Mounts the deployment-version history LiveView.

  Host applications must call this inside their authenticated superadmin scope.
  The path is configurable and conventionally `/admin/versions`.
  """
  defmacro acceptance_harness_versions(path \\ "/admin/versions") do
    quote bind_quoted: [path: path] do
      scope path, alias: false, as: :acceptance_harness_versions do
        live("/", AcceptanceHarnessWeb.VersionLive, :index)
      end
    end
  end

  @doc """
  Mounts the shared unauthenticated JSON liveness endpoint.

  Call this inside the host application's JSON/API pipeline:

      acceptance_harness_health("/health")
  """
  defmacro acceptance_harness_health(path \\ "/health") do
    controller = AcceptanceHarnessWeb.HealthController

    quote bind_quoted: [path: path, controller: controller] do
      get(path, controller, :check)
    end
  end
end
