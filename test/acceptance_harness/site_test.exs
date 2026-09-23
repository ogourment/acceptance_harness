defmodule AcceptanceHarness.SiteTest do
  use ExUnit.Case, async: true

  alias AcceptanceHarness.Site

  test "builds an iPad-friendly static report with screenshots" do
    tmp_root =
      Path.join(System.tmp_dir!(), "agile-u-atdd-site-#{System.unique_integer([:positive])}")

    source_dir = Path.join(tmp_root, "source")
    output_dir = Path.join(tmp_root, "public")

    on_exit(fn -> File.rm_rf!(tmp_root) end)

    File.mkdir_p!(Path.join(source_dir, "screenshots"))
    File.write!(Path.join(source_dir, "e2e.md"), markdown_report())
    File.write!(Path.join(source_dir, "evidence.json"), ~s({"schema_version":"test"}))
    File.write!(Path.join(source_dir, "screenshots/01-dashboard.png"), "png")

    assert :ok = Site.build!(source_dir, output_dir)

    document =
      output_dir
      |> Path.join("index.html")
      |> File.read!()
      |> LazyHTML.from_document()

    assert document |> LazyHTML.query("title") |> LazyHTML.text() == "Agile-U ATDD Evidence"
    assert document |> LazyHTML.query("h1") |> LazyHTML.text() == "Agile-U E2E evidence"
    assert document |> LazyHTML.query("nav.contents") |> LazyHTML.text() == ""

    assert ["admin-dashboard"] =
             document |> LazyHTML.query("h2") |> LazyHTML.attribute("id")

    assert ["screenshots/01-dashboard.png", "screenshots/01-dashboard.png"] =
             document |> LazyHTML.query("img") |> LazyHTML.attribute("src")

    assert ["screenshots/01-dashboard.png", "screenshots/01-dashboard.png"] =
             document |> LazyHTML.query("a.screenshot-thumb") |> LazyHTML.attribute("href")

    assert document |> LazyHTML.query("#screenshot-dialog") |> LazyHTML.attribute("aria-label") ==
             [
               "Screenshot preview"
             ]

    assert document |> LazyHTML.query(".screenshot-review-message") |> LazyHTML.text() =~
             "Admin opens"

    assert document |> LazyHTML.query("#screenshot-dialog-message") |> LazyHTML.text() == ""

    assert document |> LazyHTML.query("#screenshot-presentation-start") |> LazyHTML.text() =~
             "Start presentation"

    assert document |> LazyHTML.query("#screenshot-dialog-title") |> LazyHTML.text() == ""
    assert document |> LazyHTML.query("#screenshot-dialog-context") |> LazyHTML.text() == ""

    assert document |> LazyHTML.query("#screenshot-dialog-previous") |> LazyHTML.text() ==
             "← Previous"

    assert document |> LazyHTML.query("#screenshot-dialog-next") |> LazyHTML.text() == "Next →"

    assert document |> LazyHTML.query("#screenshot-dialog-counter") |> LazyHTML.text() == ""

    assert document |> LazyHTML.query("#screenshot-dialog-zoom-out") |> LazyHTML.text() == "−"
    assert document |> LazyHTML.query("#screenshot-dialog-zoom-in") |> LazyHTML.text() == "+"

    assert document
           |> LazyHTML.query("input[name='screenshot-dialog-fit']")
           |> LazyHTML.attribute("value") == ["width", "window"]

    assert document
           |> LazyHTML.query("input[name='screenshot-dialog-fit'][value='window']")
           |> LazyHTML.attribute("checked") == [""]

    assert document |> LazyHTML.query(".screenshot-dialog-fit-modes") |> LazyHTML.text() =~
             "Fit width"

    assert document |> LazyHTML.query(".screenshot-dialog-fit-modes") |> LazyHTML.text() =~
             "Fit window"

    assert document |> LazyHTML.query("#screenshot-dialog-zoom-level") |> LazyHTML.text() ==
             "100%"

    assert document |> LazyHTML.query("script") |> LazyHTML.text() =~ "showModal"
    assert document |> LazyHTML.query("script") |> LazyHTML.text() =~ "applyZoom"
    assert document |> LazyHTML.query("script") |> LazyHTML.text() =~ "applyFitMode"
    assert document |> LazyHTML.query("script") |> LazyHTML.text() =~ "selectedFitMode"
    assert document |> LazyHTML.query("script") |> LazyHTML.text() =~ "showScreenshot"
    assert document |> LazyHTML.query("script") |> LazyHTML.text() =~ "slideMetadata"
    assert document |> LazyHTML.query("script") |> LazyHTML.text() =~ "metadata.reviewMessage"

    assert document |> LazyHTML.query("script") |> LazyHTML.text() =~
             "startPresentation.addEventListener"

    assert document |> LazyHTML.query("script") |> LazyHTML.text() =~ "ArrowLeft"
    assert document |> LazyHTML.query("script") |> LazyHTML.text() =~ "ArrowRight"

    html = File.read!(Path.join(output_dir, "index.html"))
    assert html =~ ".screenshot-dialog-viewport"
    assert html =~ "justify-content: flex-start"

    {next_index, _} = :binary.match(html, ~s(id="screenshot-dialog-next"))
    {actions_index, _} = :binary.match(html, ~s(class="screenshot-dialog-actions"))
    assert next_index > actions_index

    assert document |> LazyHTML.query("code") |> LazyHTML.text() == "ATDD Johari Window"
    assert document |> LazyHTML.query(".inline-help") |> LazyHTML.text() == "🛈"

    assert document |> LazyHTML.query(".inline-help") |> LazyHTML.attribute("title") == [
             "Elapsed time from collector start to report generation."
           ]

    assert document |> LazyHTML.query("table th") |> LazyHTML.text() =~ "Admin"
    assert document |> LazyHTML.query("table td") |> LazyHTML.text() =~ "First scenario"

    assert document |> LazyHTML.query("table td img") |> LazyHTML.attribute("src") == [
             "screenshots/01-dashboard.png"
           ]

    assert File.exists?(Path.join(output_dir, "e2e.md"))
    assert File.exists?(Path.join(output_dir, "journeys.md"))
    assert File.read!(Path.join(output_dir, "evidence.json")) == ~s({"schema_version":"test"})
    assert File.exists?(Path.join(output_dir, "screenshots/01-dashboard.png"))
  end

  test "renders ATDD failure details as preformatted code" do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "agile-u-atdd-site-failure-#{System.unique_integer([:positive])}"
      )

    source_dir = Path.join(tmp_root, "source")
    output_dir = Path.join(tmp_root, "public")

    on_exit(fn -> File.rm_rf!(tmp_root) end)

    File.mkdir_p!(source_dir)

    File.write!(Path.join(source_dir, "e2e.md"), """
    # Agile-U E2E evidence

    ## ❌ Scenario: Auth path

    ### ❌ Failed step: test auth path (AgileUWeb.AtddTest)

    - Location: `test/agile_u_web/atdd_test.exs:12`
    - Message: Could not find element
    - Code: `assert_has(conn, "#login")`

    ```text
    ** (ArgumentError) Could not find element
        test/agile_u_web/atdd_test.exs:12
    ```

    ::: .failure-screenshot
    ![Failure screenshot 1](screenshots/failure.png)
    :::
    """)

    File.mkdir_p!(Path.join(source_dir, "screenshots"))
    File.write!(Path.join(source_dir, "screenshots/failure.png"), "png")

    assert :ok = Site.build!(source_dir, output_dir)

    document =
      output_dir
      |> Path.join("index.html")
      |> File.read!()
      |> LazyHTML.from_document()

    assert document |> LazyHTML.query("h2") |> LazyHTML.text() =~ "Auth path"
    assert document |> LazyHTML.query("h3") |> LazyHTML.text() =~ "test auth path"
    assert document |> LazyHTML.query("pre code") |> LazyHTML.text() =~ "Could not find element"
    assert document |> LazyHTML.query("pre code") |> LazyHTML.text() =~ "atdd_test.exs:12"

    assert document |> LazyHTML.query(".failure-screenshot img") |> LazyHTML.attribute("src") == [
             "screenshots/failure.png"
           ]
  end

  test "renders a terminal screen and copies declared generic artifacts" do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "acceptance-harness-terminal-#{System.unique_integer([:positive])}"
      )

    source_dir = Path.join(tmp_root, "source")
    output_dir = Path.join(tmp_root, "public")
    artifact_path = Path.join(source_dir, "artifacts/repo-health/open.ansi")

    on_exit(fn -> File.rm_rf!(tmp_root) end)

    File.mkdir_p!(Path.dirname(artifact_path))

    File.write!(Path.join(source_dir, "e2e.md"), """
    # Terminal evidence

    ```terminal
    Repository health
    ⚠ a55ist  dirty (1 modified)
    ```
    """)

    File.write!(artifact_path, "\e[33m⚠ a55ist\e[0m")

    File.write!(
      Path.join(source_dir, "evidence.json"),
      Jason.encode!(%{
        "schema_version" => "acceptance_harness.evidence.v1",
        "artifacts" => [],
        "scenarios" => [
          %{
            "steps" => [
              %{
                "artifacts" => [
                  %{
                    "type" => "terminal_ansi",
                    "path" => "artifacts/repo-health/open.ansi"
                  }
                ]
              }
            ]
          }
        ]
      })
    )

    assert :ok = Site.build!(source_dir, output_dir)

    document =
      output_dir
      |> Path.join("index.html")
      |> File.read!()
      |> LazyHTML.from_document()

    assert document |> LazyHTML.query("pre code") |> LazyHTML.text() =~ "Repository health"
    assert document |> LazyHTML.query("pre code") |> LazyHTML.text() =~ "dirty (1 modified)"

    assert File.read!(Path.join(output_dir, "artifacts/repo-health/open.ansi")) ==
             "\e[33m⚠ a55ist\e[0m"
  end

  test "rejects declared artifacts outside the evidence directory" do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "acceptance-harness-artifact-#{System.unique_integer([:positive])}"
      )

    source_dir = Path.join(tmp_root, "source")
    output_dir = Path.join(tmp_root, "public")

    on_exit(fn -> File.rm_rf!(tmp_root) end)

    File.mkdir_p!(source_dir)
    File.write!(Path.join(source_dir, "e2e.md"), "# Evidence")

    write_artifact_evidence(source_dir, "../secret.txt")

    assert_raise ArgumentError, ~r/artifact path must stay within/, fn ->
      Site.build!(source_dir, output_dir)
    end
  end

  test "rejects declared artifacts reached through a symlink" do
    tmp_root =
      Path.join(
        System.tmp_dir!(),
        "acceptance-harness-symlink-#{System.unique_integer([:positive])}"
      )

    source_dir = Path.join(tmp_root, "source")
    output_dir = Path.join(tmp_root, "public")
    outside_dir = Path.join(tmp_root, "outside")

    on_exit(fn -> File.rm_rf!(tmp_root) end)

    File.mkdir_p!(source_dir)
    File.mkdir_p!(outside_dir)
    File.write!(Path.join(source_dir, "e2e.md"), "# Evidence")
    File.write!(Path.join(outside_dir, "raw.ansi"), "secret")
    File.ln_s!(outside_dir, Path.join(source_dir, "artifacts"))
    write_artifact_evidence(source_dir, "artifacts/raw.ansi")

    assert_raise ArgumentError, ~r/artifact path must not contain symlinks/, fn ->
      Site.build!(source_dir, output_dir)
    end
  end

  defp write_artifact_evidence(source_dir, path) do
    File.write!(
      Path.join(source_dir, "evidence.json"),
      Jason.encode!(%{
        "artifacts" => [%{"type" => "debug", "path" => path}],
        "scenarios" => []
      })
    )
  end

  defp markdown_report do
    """
    # Agile-U E2E evidence

    ## Admin dashboard

    | # | Status | Scenario | Devices | Themes | Duration |
    | --- | --- | --- | --- | --- | --- |
    | 1 | ✅ | [First scenario](#first-scenario) | Desktop | dark | 42 ms |
    | 2 | ❌ | [Second scenario](#second-scenario) | Phone | light | 7 ms |

    | Step | Admin | Alice |
    | --- | --- | --- |
    | 1/2 | ![Admin opens](screenshots/01-dashboard.png) | - |

    The admin opens the dashboard.

    The journey is `ATDD Johari Window`.

    Report wall time {{help:Elapsed time from collector start to report generation.}}: **6s**

    ![Admin dashboard](screenshots/01-dashboard.png)
    """
  end
end
