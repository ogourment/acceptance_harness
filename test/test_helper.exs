case AcceptanceHarness.TestDb.setup_test_db() do
  {:ok, _db_config} ->
    ExUnit.start()

  :error ->
    IO.puts("Postgres unavailable — excluding :db tests")
    ExUnit.start(exclude: [:db])
end

Application.put_env(:acceptance_harness, :harness,
  app_name: "Agile-U",
  otp_app: :acceptance_harness,
  site_title: "Agile-U ATDD Evidence",
  commit_sha_env: ["ACCEPTANCE_GIT_SHA", "CI_COMMIT_SHA"],
  scenario_title_aliases: %{
    "admin reaches the journey presenter through the UI" =>
      "Admin opens a live journey presenter through UI navigation",
    "participant can start before authentication and is later asked to identify themselves" =>
      "Participant starts Johari anonymously and reaches the peer-selection auth gate",
    "five-person Johari workshop reaches a revealed processed board" =>
      "Johari facilitator reveals a processed board for a five-person workshop",
    "three-user Johari workshop documents a compact multi-user view" =>
      "Johari multi-user evidence stays readable with three users",
    "mistyped active journey URL suggests the close match" =>
      "Mistyped journey URL suggests the close active journey",
    "auth pages and emails preserve journey return paths" =>
      "Auth pages and emails preserve journey return paths",
    "phone participant completes a Johari journey in light mode" =>
      "Phone participant creates an account during a French Johari journey in light mode",
    "superadmin examines the version page through admin navigation" =>
      "Superadmin examines the deployed version page",
    "user reviews Brevo subscription status through the account menu" =>
      "User reviews Brevo newsletter subscription status"
  }
)
