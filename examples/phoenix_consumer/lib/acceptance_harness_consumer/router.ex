defmodule AcceptanceHarnessConsumer.Router do
  use Phoenix.Router

  import AcceptanceHarnessWeb.Router
  import Phoenix.Controller
  import Phoenix.LiveView.Router

  pipeline :browser do
    plug(:accepts, ["html"])
    plug(:fetch_query_params)
    plug(:fetch_session)
    plug(:protect_from_forgery)
    plug(:put_root_layout, html: {AcceptanceHarnessConsumerWeb.Layouts, :root})
  end

  pipeline :api do
    plug(:accepts, ["json"])
  end

  pipeline :require_superadmin do
    plug(:enforce_superadmin)
  end

  scope "/" do
    pipe_through(:api)

    acceptance_harness_health("/health")
  end

  scope "/admin" do
    pipe_through([:browser, :require_superadmin])

    acceptance_harness("/acceptance")
    acceptance_harness_versions("/versions")
  end

  if Mix.env() == :test do
    scope "/test/atdd" do
      pipe_through(:browser)

      get("/login", AcceptanceHarnessConsumerWeb.ATDDLoginController, :show)
    end
  end

  def enforce_superadmin(conn, _opts) do
    if get_req_header(conn, "x-superadmin") == ["true"] or
         atdd_superadmin?(conn) do
      conn
    else
      conn |> send_resp(403, "superadmin required") |> halt()
    end
  end

  if Mix.env() == :test do
    defp atdd_superadmin?(conn) do
      System.get_env("ATDD") == "true" and get_session(conn, :atdd_superadmin) == true
    end
  else
    defp atdd_superadmin?(_conn), do: false
  end
end
