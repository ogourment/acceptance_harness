import Config

atdd_port = System.get_env("ATDD_PORT", "4002") |> String.to_integer()
test_partition = System.get_env("MIX_TEST_PARTITION", "")

artifact_namespace =
  if test_partition == "", do: "port-#{atdd_port}", else: "partition-#{test_partition}"

artifact_namespace =
  artifact_namespace
  |> String.replace(~r/[^a-zA-Z0-9._-]/, "-")
  |> Kernel.<>("-run-#{System.system_time(:millisecond)}")

consumer_root = Path.expand("..", __DIR__)

atdd_artifact_root =
  case System.get_env("ATDD_ARTIFACT_ROOT") do
    nil -> Path.join([consumer_root, "tmp", "atdd", artifact_namespace])
    configured -> Path.expand(configured, consumer_root)
  end

config :acceptance_harness_consumer,
  ecto_repos: [AcceptanceHarnessConsumer.Repo]

config :acceptance_harness_consumer, AcceptanceHarnessConsumer.Repo,
  database: "acceptance_harness_consumer_test#{test_partition}"

config :acceptance_harness_consumer, AcceptanceHarnessConsumer.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: atdd_port],
  server: System.get_env("ATDD") == "true"

config :phoenix_test,
  otp_app: :acceptance_harness_consumer,
  base_url: System.get_env("ATDD_BASE_URL", "http://localhost:#{atdd_port}"),
  playwright: [
    assets_dir: Path.expand("../assets", __DIR__),
    screenshot_dir: Path.join(atdd_artifact_root, "screenshots"),
    trace_dir: Path.join(atdd_artifact_root, "traces"),
    timeout: 10_000
  ]

config :acceptance_harness, :harness,
  evidence_dir: atdd_artifact_root,
  screenshot_dir: Path.join(atdd_artifact_root, "screenshots"),
  trace_dir: Path.join(atdd_artifact_root, "traces")

config :logger, level: :warning
