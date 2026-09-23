defmodule AcceptanceHarnessWeb.ArtifactController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]

  alias AcceptanceHarness.AdminStore

  def show(conn, %{"run_id" => run_id, "path" => path}) do
    relative_path = Path.join(List.wrap(path))

    case AdminStore.artifact_location(run_id, relative_path) do
      {:file, local_path} ->
        conn
        |> Plug.Conn.put_resp_content_type(MIME.from_path(local_path), nil)
        |> Plug.Conn.send_file(200, local_path)

      {:url, url} ->
        Phoenix.Controller.redirect(conn, external: url)

      :error ->
        Plug.Conn.send_resp(conn, 404, "Artifact not found")
    end
  end
end
