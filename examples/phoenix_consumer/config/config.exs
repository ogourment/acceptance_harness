import Config

config :acceptance_harness_consumer, AcceptanceHarnessConsumer.Repo,
  username: System.get_env("ACCEPTANCE_HARNESS_TEST_DB_USER", System.get_env("USER", "postgres")),
  password: System.get_env("ACCEPTANCE_HARNESS_TEST_DB_PASSWORD"),
  hostname: System.get_env("ACCEPTANCE_HARNESS_TEST_DB_HOST", "localhost"),
  database: "acceptance_harness_consumer_test",
  pool: Ecto.Adapters.SQL.Sandbox,
  pool_size: 2

config :acceptance_harness_consumer, AcceptanceHarnessConsumer.Endpoint,
  url: [host: "localhost"],
  render_errors: [formats: [html: AcceptanceHarnessConsumer.ErrorHTML], layout: false],
  pubsub_server: AcceptanceHarnessConsumer.PubSub,
  live_view: [signing_salt: "consumer-live-view-signing-salt"],
  secret_key_base:
    "acceptance-harness-consumer-test-secret-key-base-012345678901234567890123456789"

config :acceptance_harness, :harness,
  app_name: "Harness consumer sample",
  otp_app: :acceptance_harness_consumer,
  site_title: "Harness consumer acceptance evidence",
  repo: AcceptanceHarnessConsumer.Repo,
  admin_acceptance_path: "/admin/acceptance",
  admin_versions_path: "/admin/versions"

config :acceptance_harness, :health,
  otp_app: :acceptance_harness_consumer,
  env_prefix: "ACCEPTANCE_HARNESS_CONSUMER"

if socket_dir = System.get_env("ACCEPTANCE_HARNESS_TEST_DB_SOCKET") do
  config :acceptance_harness_consumer, AcceptanceHarnessConsumer.Repo, socket_dir: socket_dir
end

import_config "#{config_env()}.exs"
