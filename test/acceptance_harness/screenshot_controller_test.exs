defmodule AcceptanceHarnessWeb.ScreenshotControllerTest do
  use ExUnit.Case, async: false

  import Plug.Conn
  import Plug.Test

  @moduletag :db

  alias AcceptanceHarness.AdminStore
  alias AcceptanceHarness.TestRepo
  alias AcceptanceHarnessWeb.ScreenshotController

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
        "acceptance-harness-screenshot-controller-#{System.unique_integer([:positive])}"
      )

    screenshot_path = Path.join([source_dir, "screenshots", "checkout.png"])
    thumbnail_path = Path.join([source_dir, "thumbnails", "checkout.webp"])
    File.mkdir_p!(Path.dirname(screenshot_path))
    File.mkdir_p!(Path.dirname(thumbnail_path))
    File.write!(screenshot_path, "full png")
    File.write!(thumbnail_path, "small webp")

    AdminStore.import_evidence_data!(
      %{
        "title" => "Evidence",
        "run" => %{"id" => "run-1"},
        "scenarios" => []
      },
      repo: TestRepo,
      source_dir: source_dir
    )

    on_exit(fn ->
      File.rm_rf!(source_dir)
      Application.put_env(:acceptance_harness, :harness, original_config)
    end)

    :ok
  end

  test "serves a WebP thumbnail for an overview request" do
    conn =
      :get
      |> conn("/admin/acceptance/screenshots/run-1/checkout.png?variant=thumbnail")
      |> ScreenshotController.show(%{
        "run_id" => "run-1",
        "filename" => "checkout.png",
        "variant" => "thumbnail"
      })

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/webp"]
    assert conn.resp_body == "small webp"
  end

  test "serves the original PNG for a detail request" do
    conn =
      :get
      |> conn("/admin/acceptance/screenshots/run-1/checkout.png")
      |> ScreenshotController.show(%{"run_id" => "run-1", "filename" => "checkout.png"})

    assert conn.status == 200
    assert get_resp_header(conn, "content-type") == ["image/png"]
    assert conn.resp_body == "full png"
  end
end
