defmodule AcceptanceHarness.Terminal.EvidenceIntegrationTest do
  use ExUnit.Case, async: false

  alias AcceptanceHarness.Terminal.{Assertions, Evidence, PortTransport, Screen}

  @helper Path.expand(
            "../../native/pty_helper/target/release/acceptance-harness-pty-helper",
            __DIR__
          )

  setup do
    evidence_dir =
      Path.join(
        System.tmp_dir!(),
        "acceptance-terminal-evidence-#{System.unique_integer([:positive])}"
      )

    original_harness = Application.get_env(:acceptance_harness, :harness)

    Application.put_env(:acceptance_harness, :harness,
      app_name: "AcceptanceHarness",
      otp_app: :acceptance_harness,
      evidence_dir: evidence_dir,
      screenshot_dir: Path.join(evidence_dir, "screenshots")
    )

    on_exit(fn ->
      File.rm_rf!(evidence_dir)

      if original_harness do
        Application.put_env(:acceptance_harness, :harness, original_harness)
      else
        Application.delete_env(:acceptance_harness, :harness)
      end
    end)

    {:ok, evidence_dir: evidence_dir}
  end

  test "normalizes a deterministic ANSI fixture and persists text plus raw evidence", %{
    evidence_dir: evidence_dir
  } do
    script = ~S"""
    printf '\033[2J\033[H'
    printf '\033[1;34mRepository health\033[0m\r\n'
    printf 'obsolete\r\033[2K12 repositories checked\r\n'
    printf 'a55ist  \033[33mdirty\033[0m'
    printf '\r\nUnicode: caf'
    printf '\303'; sleep 0.02; printf '\251 \316'; sleep 0.02; printf '\224'
    sleep 30
    """

    assert {:ok, session} =
             PortTransport.start(
               command: ["/bin/sh", "-c", script],
               rows: 6,
               cols: 48,
               helper_path: @helper
             )

    raw = collect_raw_until(session, &String.contains?(&1, "Unicode: café Δ"))
    assert {:ok, screen} = Screen.snapshot(PortTransport, session)
    assert :ok = Assertions.assert_row!(screen, 1, "Repository health")
    assert :ok = Assertions.assert_visible!(screen, "12 repositories checked")
    assert :ok = Assertions.assert_row!(screen, 3, "a55ist  dirty")
    assert :ok = Assertions.assert_row!(screen, 4, "Unicode: café Δ")

    AcceptanceHarness.Evidence.reset!("Terminal ATDD", [
      %{id: "terminal-fixture", title: "Terminal fixture"}
    ])

    Evidence.record_step!(
      screen,
      raw,
      "Open terminal fixture",
      "Shows normalized terminal status.",
      artifact_name: "terminal-fixture/open",
      metadata: %{"scenario_id" => "terminal-fixture"}
    )

    AcceptanceHarness.Evidence.mark_scenario_success!(%{
      id: "terminal-fixture",
      title: "Terminal fixture"
    })

    AcceptanceHarness.Evidence.finalize!()

    assert File.read!(Path.join(evidence_dir, "artifacts/terminal-fixture/open.ansi")) == raw

    assert File.read!(Path.join(evidence_dir, "artifacts/terminal-fixture/open.txt")) ==
             Screen.text(screen)

    report = AcceptanceHarness.Evidence.report_json_path() |> File.read!() |> Jason.decode!()
    [scenario] = report["scenarios"]
    [step] = scenario["steps"]
    assert step["surface"]["text"] =~ "a55ist  dirty"
    assert Enum.map(step["artifacts"], & &1["type"]) == ["terminal_ansi", "terminal_text"]

    assert :ok = PortTransport.stop(session, :scenario_complete)
  end

  test "refuses to write terminal evidence through a symlink", %{evidence_dir: evidence_dir} do
    outside = evidence_dir <> "-outside"
    File.mkdir_p!(outside)
    File.mkdir_p!(Path.join(evidence_dir, "artifacts"))
    File.ln_s!(outside, Path.join(evidence_dir, "artifacts/linked"))
    screen = Screen.new(%{rows: 1, columns: 20, text: "safe"})

    assert_raise ArgumentError, ~r/must not contain symlinks/, fn ->
      Evidence.record_step!(screen, "raw", "Unsafe", "Unsafe path",
        artifact_name: "linked/escape"
      )
    end

    refute File.exists?(Path.join(outside, "escape.ansi"))
    File.rm_rf!(outside)
  end

  defp collect_raw_until(session, predicate, buffer \\ "") do
    receive do
      {:terminal_transport, ^session, {:output, bytes}} ->
        buffer = buffer <> bytes
        if predicate.(buffer), do: buffer, else: collect_raw_until(session, predicate, buffer)
    after
      2_000 -> flunk("timed out waiting for terminal fixture output: #{inspect(buffer)}")
    end
  end
end
