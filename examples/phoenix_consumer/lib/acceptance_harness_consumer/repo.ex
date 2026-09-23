defmodule AcceptanceHarnessConsumer.Repo do
  use Ecto.Repo,
    otp_app: :acceptance_harness_consumer,
    adapter: Ecto.Adapters.Postgres
end
