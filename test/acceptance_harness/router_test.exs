defmodule AcceptanceHarnessWeb.RouterTest do
  use ExUnit.Case, async: true

  defmodule AdminRouter do
    use Phoenix.Router
    import AcceptanceHarnessWeb.Router
    import Phoenix.LiveView.Router

    scope "/admin" do
      acceptance_harness("/acceptance", live: false)
    end
  end

  test "agent API mount is retired" do
    refute {:acceptance_harness_agent_api, 1} in AcceptanceHarnessWeb.Router.__info__(:macros)
  end

  test "authenticated admin mount has no export or work-status routes" do
    routes = Phoenix.Router.routes(AdminRouter)

    refute Enum.any?(routes, &String.contains?(&1.path, "/export"))
    refute Enum.any?(routes, &String.contains?(&1.path, "/work-statuses"))
  end
end
