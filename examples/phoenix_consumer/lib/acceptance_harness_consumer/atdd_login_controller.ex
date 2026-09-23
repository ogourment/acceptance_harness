if Mix.env() == :test do
  defmodule AcceptanceHarnessConsumerWeb.ATDDLoginController do
    use Phoenix.Controller, formats: [:html]

    def show(conn, %{"as" => "reviewer"}) do
      if System.get_env("ATDD") == "true" do
        conn
        |> put_session(:atdd_superadmin, true)
        |> redirect(to: "/admin/acceptance")
      else
        send_resp(conn, 404, "not found")
      end
    end

    def show(conn, _params) do
      if System.get_env("ATDD") == "true" do
        html(
          conn,
          """
          <!doctype html><html lang="en"><head><meta charset="utf-8"><title>ATDD reviewer sign in</title></head>
          <body><main><h1>ATDD reviewer sign in</h1><p>Local isolated test fixture; no external account is used.</p>
          <a href="/test/atdd/login?as=reviewer">Continue as isolated reviewer</a></main></body></html>
          """
        )
      else
        send_resp(conn, 404, "not found")
      end
    end
  end
end
