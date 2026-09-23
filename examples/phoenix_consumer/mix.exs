defmodule AcceptanceHarnessConsumer.MixProject do
  use Mix.Project

  def project do
    [
      app: :acceptance_harness_consumer,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps()
    ]
  end

  def application do
    [
      mod: {AcceptanceHarnessConsumer.Application, []},
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:acceptance_harness, path: "../.."},
      {:ecto_sql, "~> 3.13"},
      {:lazy_html, ">= 0.1.0", only: :test},
      {:phoenix_test_playwright, "~> 0.16.0", only: :test, runtime: false},
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:plug_cowboy, "~> 2.7", only: :test},
      {:postgrex, ">= 0.0.0"}
    ]
  end
end
