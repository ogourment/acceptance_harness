defmodule AcceptanceHarnessConsumer.Endpoint do
  use Phoenix.Endpoint, otp_app: :acceptance_harness_consumer

  @session_options [
    store: :cookie,
    key: "_acceptance_harness_consumer_key",
    signing_salt: "consumer-signing-salt"
  ]

  socket("/live", Phoenix.LiveView.Socket, websocket: [connect_info: [session: @session_options]])

  plug(Plug.Static,
    at: "/assets",
    from: {:acceptance_harness_consumer, "priv/static/assets"}
  )

  plug(Plug.Static,
    at: "/assets",
    from: {:phoenix_live_view, "priv/static"}
  )

  plug(Plug.Static,
    at: "/assets",
    from: {:phoenix, "priv/static"}
  )

  plug(Plug.Parsers, parsers: [:urlencoded, :multipart, :json], pass: ["*/*"], json_decoder: Jason)
  plug(Plug.Session, @session_options)
  plug(AcceptanceHarnessConsumer.Router)
end
