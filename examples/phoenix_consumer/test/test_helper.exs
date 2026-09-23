repo_config = Application.fetch_env!(:acceptance_harness_consumer, AcceptanceHarnessConsumer.Repo)

case Ecto.Adapters.Postgres.storage_up(repo_config) do
  :ok -> :ok
  {:error, :already_up} -> :ok
end

{:ok, _repo} = AcceptanceHarnessConsumer.Repo.start_link()

if System.get_env("ATDD") == "true" do
  {:ok, _} = PhoenixTest.Playwright.Supervisor.start_link()
end

Code.require_file("support/conn_case.ex", __DIR__)

Code.require_file("support/review_evidence.ex", __DIR__)

ExUnit.start(exclude: [:atdd])
