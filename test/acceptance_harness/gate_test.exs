defmodule AcceptanceHarness.GateTest do
  use ExUnit.Case

  alias AcceptanceHarness.Gate

  setup do
    dir =
      Path.join(
        System.tmp_dir!(),
        "acceptance-harness-gate-#{System.unique_integer([:positive])}"
      )

    File.mkdir_p!(dir)

    on_exit(fn -> File.rm_rf!(dir) end)

    %{dir: dir}
  end

  test "portable artifact gate preserves the existing pass/fail contract", %{dir: dir} do
    for status <- ["ATDD_TEST_EXIT_CODE=0", "ATDD_TEST_EXIT_CODE=7", "OTHER=1"],
        report <- [
          "| 1 | ✅ | passed |",
          "| 1 | 🟠 | known gap |",
          "| 1 | ⬛ | unavailable |",
          "| 1 | ⚪ | not run |",
          "| 1 | ✅ | passed |\n## Test Failures",
          "No rows"
        ] do
      status_path = write!(dir, "portable-status.env", status)
      report_path = write!(dir, "portable-report.md", report)

      {_output, exit_code} =
        System.cmd(Path.expand("../../bin/acceptance-gate", __DIR__), [status_path, report_path],
          stderr_to_stdout: true
        )

      assert exit_code == 0 == (Gate.check(status_path, report_path) == :ok)
    end
  end

  test "check/2 passes for clean inputs", %{dir: dir} do
    status_path = write!(dir, "status.env", "ATDD_TEST_EXIT_CODE=0")

    report_path =
      write!(dir, "e2e.md", """
      | n | status | scenario |
      | 1 | ✅ | login succeeds |
      """)

    assert Gate.check(status_path, report_path) == :ok
  end

  test "check/2 accepts explicitly ignored and skipped scenarios", %{dir: dir} do
    status_path = write!(dir, "status.env", "ATDD_TEST_EXIT_CODE=0")

    report_path =
      write!(dir, "e2e.md", """
      | n | status | scenario |
      | 1 | ✅ | login succeeds |
      | 2 | 🟠 | known product gap |
      | 3 | ⬛ | unavailable environment |
      """)

    assert Gate.check(status_path, report_path) == :ok
  end

  test "check/2 fails with missing status file", %{dir: dir} do
    report_path =
      write!(dir, "e2e.md", """
      | n | status | scenario |
      | 1 | ✅ | login succeeds |
      """)

    assert {:error, messages} = Gate.check("missing-status.env", report_path)
    assert ["missing status file: missing-status.env"] == messages
  end

  test "check/2 fails when exit code is missing, non-numeric, or nonzero", %{dir: dir} do
    report_path =
      write!(dir, "e2e.md", """
      | n | status | scenario |
      | 1 | ✅ | login succeeds |
      """)

    status_path_non_numeric = write!(dir, "status.env", "ATDD_TEST_EXIT_CODE=foo")
    status_path_nonzero = write!(dir, "status-nonzero.env", "ATDD_TEST_EXIT_CODE=7")
    status_path_missing = write!(dir, "status-missing.env", "OTHER=1")

    assert {:error, messages} = Gate.check(status_path_non_numeric, report_path)
    assert ["ATDD_TEST_EXIT_CODE is missing or invalid"] == messages

    assert {:error, messages} = Gate.check(status_path_nonzero, report_path)
    assert ["ATDD_TEST_EXIT_CODE=7"] == messages

    assert {:error, messages} = Gate.check(status_path_missing, report_path)
    assert ["ATDD_TEST_EXIT_CODE is missing or invalid"] == messages
  end

  test "check/2 fails when report has no scenario summary rows", %{dir: dir} do
    status_path = write!(dir, "status.env", "ATDD_TEST_EXIT_CODE=0")
    report_path = write!(dir, "e2e.md", "No summary table here.")

    assert {:error, messages} = Gate.check(status_path, report_path)
    assert ["evidence report has no scenario summary rows"] == messages
  end

  test "check/2 fails when any scenario status is not check-mark green", %{dir: dir} do
    status_path = write!(dir, "status.env", "ATDD_TEST_EXIT_CODE=0")

    report_path =
      write!(dir, "e2e.md", """
      | n | status | scenario |
      | 1 | ❌ | login fails |
      """)

    assert {:error, messages} = Gate.check(status_path, report_path)
    assert "evidence report contains non-passing scenario status:" in messages
    assert "scenario 1 status ❌" in messages
  end

  test "check/2 fails when report includes failure sections", %{dir: dir} do
    status_path = write!(dir, "status.env", "ATDD_TEST_EXIT_CODE=0")

    report_path =
      write!(dir, "e2e.md", """
      | n | status | scenario |
      | 1 | ✅ | login succeeds |

      ## Test Failures
      ## ❌ Scenario: broken
      """)

    assert {:error, messages} = Gate.check(status_path, report_path)
    assert "evidence report contains a Test Failures section" in messages
    assert "evidence report contains failed, missing, or running scenario sections" in messages
  end

  test "check!/2 raises with joined messages", %{dir: dir} do
    status_path = write!(dir, "status.env", "ATDD_TEST_EXIT_CODE=1")
    report_path = write!(dir, "e2e.md", "No summary table here.")

    assert_raise RuntimeError, ~r/ATDD_TEST_EXIT_CODE=1/, fn ->
      Gate.check!(status_path, report_path)
    end
  end

  defp write!(dir, name, content) do
    path = Path.join(dir, name)
    File.write!(path, String.trim_trailing(content))
    path
  end
end
