defmodule AcceptanceHarnessWeb.ScreenshotController do
  @moduledoc false
  use Phoenix.Controller, formats: [:html]

  alias AcceptanceHarness.AdminStore

  def show(conn, %{"run_id" => run_id, "filename" => filename} = params) do
    variant = if params["variant"] == "thumbnail", do: :thumbnail, else: :original

    case AdminStore.screenshot_location(run_id, filename, variant: variant) do
      {:file, path} ->
        conn
        |> Plug.Conn.put_resp_content_type(MIME.from_path(path), nil)
        |> Plug.Conn.send_file(200, path)

      {:url, url} ->
        Phoenix.Controller.redirect(conn, external: url)

      :error ->
        Plug.Conn.send_resp(conn, 404, "Screenshot not found")
    end
  end
end
