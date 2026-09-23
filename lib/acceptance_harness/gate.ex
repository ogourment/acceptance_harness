defmodule AcceptanceHarness.Gate do
  @moduledoc """
  ATDD gate checks for the acceptance test exit status and report.
  """

  @status_default_path "tmp/atdd/status.env"
  @report_default_path "tmp/atdd/e2e.md"

  @doc """
  Verifies gate inputs.

  Returns `:ok` when all checks pass, otherwise `{:error, [messages]}`.
  """
  @spec check(String.t(), String.t()) :: :ok | {:error, [String.t()]}
  def check(status_path \\ @status_default_path, report_path \\ @report_default_path) do
    messages =
      []
      |> check_status_file(status_path)
      |> check_report_file(report_path)

    if messages == [] do
      :ok
    else
      {:error, messages}
    end
  end

  @doc """
  Same as `check/2` but raises on failure.
  """
  @spec check!(String.t(), String.t()) :: :ok | no_return()
  def check!(status_path \\ @status_default_path, report_path \\ @report_default_path) do
    case check(status_path, report_path) do
      :ok ->
        :ok

      {:error, messages} ->
        raise RuntimeError, "ATDD gate failed:\n#{Enum.join(messages, "\n")}"
    end
  end

  defp check_status_file(messages, status_path) do
    case File.read(status_path) do
      {:ok, content} ->
        case extract_exit_code(content) do
          {:ok, "0"} ->
            messages

          {:ok, code} ->
            ["ATDD_TEST_EXIT_CODE=#{code}" | messages]

          {:error, reason} ->
            [reason | messages]
        end

      {:error, _reason} ->
        ["missing status file: #{status_path}" | messages]
    end
  end

  defp extract_exit_code(content) do
    content
    |> find_status_value("ATDD_TEST_EXIT_CODE")
    |> case do
      {:ok, value} ->
        if Regex.match?(~r/^\d+$/, value) do
          {:ok, value}
        else
          {:error, "ATDD_TEST_EXIT_CODE is missing or invalid"}
        end

      :missing ->
        {:error, "ATDD_TEST_EXIT_CODE is missing or invalid"}
    end
  end

  defp find_status_value(content, key) do
    content
    |> String.split("\n")
    |> Enum.reduce_while(:missing, fn line, _acc ->
      case String.split(line, "=", parts: 2) do
        [name, value] ->
          if String.trim(name) == key do
            {:halt, {:ok, String.trim(value)}}
          else
            {:cont, :missing}
          end

        _ ->
          {:cont, :missing}
      end
    end)
  end

  defp check_report_file(messages, report_path) do
    case File.read(report_path) do
      {:ok, report} ->
        messages
        |> check_report_rows(report)
        |> check_non_green_status(report)
        |> maybe_check_contains(
          report,
          "## Test Failures",
          "evidence report contains a Test Failures section"
        )
        |> maybe_check_contains_any(
          report,
          [
            "## ❌ Scenario:",
            "## ⚪ Scenario:",
            "## ⏳ Scenario:"
          ],
          "evidence report contains failed, missing, or running scenario sections"
        )

      {:error, _reason} ->
        ["missing evidence report: #{report_path}" | messages]
    end
  end

  defp check_report_rows(messages, report) do
    scenario_rows =
      report
      |> String.split("\n")
      |> Enum.count(&scenario_row?/1)

    if scenario_rows == 0 do
      ["evidence report has no scenario summary rows" | messages]
    else
      messages
    end
  end

  defp scenario_row?(line) do
    String.match?(line, ~r/^\|\s*[0-9]+\s*\|/)
  end

  defp check_non_green_status(messages, report) do
    non_green =
      report
      |> String.split("\n")
      |> Enum.filter(&scenario_row?/1)
      |> Enum.map(fn line ->
        line
        |> String.split("|", trim: true)
        |> Enum.map(&String.trim/1)
      end)
      |> Enum.filter(&(length(&1) >= 2))
      |> Enum.reject(fn [_index, status | _rest] ->
        Enum.any?(["✅", "🟠", "⬛"], &String.contains?(status, &1))
      end)
      |> Enum.map(fn [index, status | _rest] -> "scenario #{index} status #{status}" end)

    if non_green == [] do
      messages
    else
      ["evidence report contains non-passing scenario status:" | non_green] ++ messages
    end
  end

  defp maybe_check_contains(messages, report, needle, label) do
    if String.contains?(report, needle) do
      [label | messages]
    else
      messages
    end
  end

  defp maybe_check_contains_any(messages, report, needles, label) when is_list(needles) do
    if Enum.any?(needles, &String.contains?(report, &1)) do
      [label | messages]
    else
      messages
    end
  end
end
