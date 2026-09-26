defmodule AcceptanceHarness.MixProject do
  use Mix.Project

  def project do
    [
      app: :acceptance_harness,
      version: "0.11.3",
      elixir: "~> 1.18",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps(),
      package: package(),
      description: description()
    ]
  end

  # Run "mix help compile.app" to learn about applications.
  def application do
    [
      mod: {AcceptanceHarness.Application, []},
      extra_applications: [:logger, :inets, :ssl]
    ]
  end

  # Run "mix help deps" to learn about dependencies.
  defp deps do
    [
      {:jason, "~> 1.4"},
      {:phoenix, "~> 1.8"},
      {:phoenix_html, "~> 4.1"},
      {:phoenix_live_view, "~> 1.1.33 or ~> 1.2.9"},
      {:plug, "~> 1.16.6 or ~> 1.17.4 or ~> 1.18.5 or ~> 1.19.5 or ~> 1.20.3"},
      {:ecto_sql, "~> 3.13", optional: true},
      {:phoenix_test_playwright, "~> 0.16.0", only: :test},
      {:postgrex, "~> 0.22.4", only: :test},
      {:lazy_html, ">= 0.1.0", only: :test}
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  defp aliases do
    [
      "ecto.setup": ["acceptance_harness.setup_test_db"]
    ]
  end

  defp description do
    "Reusable Phoenix acceptance-test evidence, diagnostics, and deployment gate harness."
  end

  defp package do
    [
      licenses: ["Apache-2.0"],
      links: %{}
    ]
  end
end
