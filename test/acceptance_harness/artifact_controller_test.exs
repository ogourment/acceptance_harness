defmodule AcceptanceHarnessWeb.ArtifactControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  @moduletag :db

  alias AcceptanceHarness.AdminStore
  alias AcceptanceHarness.TestRepo
  alias AcceptanceHarnessWeb.ArtifactController

  setup do
    original_config = Application.get_env(:acceptance_harness, :harness, [])

    Application.put_env(
      :acceptance_harness,
      :harness,
      Keyword.put(original_config, :repo, TestRepo)
    )

    AdminStore.install!(repo: TestRepo)

    Ecto.Adapters.SQL.query!(
      TestRepo,
      "TRUNCATE acceptance_harness_runs CASCADE",
      []
    )

    source_dir =
      Path.join(
        System.tmp_dir!(),
        "acceptance-harness-artifact-controller-#{System.unique_integer([:positive])}"
      )

    artifact_path = Path.join([source_dir, "schema", "domains", "identity.svg"])
    File.mkdir_p!(Path.dirname(artifact_path))
    File.write!(artifact_path, "<svg>identity</svg>")

    AdminStore.import_evidence_data!(
      %{"title" => "Evidence", "run" => %{"id" => "run-1"}, "scenarios" => []},
      repo: TestRepo,
      source_dir: source_dir
    )

    on_exit(fn ->
      File.rm_rf!(source_dir)
      Application.put_env(:acceptance_harness, :harness, original_config)
    end)

    :ok
  end

  test "serves a nested schema artifact" do
    conn =
      :get
      |> conn("/admin/acceptance/artifacts/run-1/schema/domains/identity.svg")
      |> ArtifactController.show(%{
        "run_id" => "run-1",
        "path" => ["schema", "domains", "identity.svg"]
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/svg+xml"]
    assert conn.resp_body == "<svg>identity</svg>"
  end

  test "rejects traversal outside the retained run directory" do
    conn =
      :get
      |> conn("/admin/acceptance/artifacts/run-1/../secret")
      |> ArtifactController.show(%{"run_id" => "run-1", "path" => ["..", "secret"]})

    assert conn.status == 404
  end
end
