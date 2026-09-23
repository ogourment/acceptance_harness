if Code.ensure_loaded?(Ecto.Repo) and Code.ensure_loaded?(Ecto.Adapters.Postgres) do
  defmodule AcceptanceHarness.TestRepo do
    @moduledoc """
    Postgres repo used by DB-backed store tests.

    Started by `test_helper.exs` when a local Postgres server is reachable;
    otherwise tests tagged `:db` are excluded.

    Database-free consumers do not load this internal test-only module.
    """

    use Ecto.Repo, otp_app: :acceptance_harness, adapter: Ecto.Adapters.Postgres
  end
end
