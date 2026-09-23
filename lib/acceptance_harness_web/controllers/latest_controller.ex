defmodule AcceptanceHarnessWeb.LatestController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]

  alias AcceptanceHarness.AdminStore

  def show(conn, _params) do
    case AdminStore.latest_run() do
      %{id: run_id} ->
        Phoenix.Controller.redirect(conn, to: latest_run_path(conn, run_id))

      %{"id" => run_id} ->
        Phoenix.Controller.redirect(conn, to: latest_run_path(conn, run_id))

      nil ->
        Phoenix.Controller.redirect(conn,
          to: String.replace_suffix(conn.request_path, "/latest", "")
        )
    end
  end

  defp latest_run_path(conn, run_id) do
    conn.request_path
    |> String.replace_suffix("/latest", "/runs/#{URI.encode_www_form(run_id)}")
  end
end
