defmodule AcceptanceHarness.SchemaArtifactWriter do
  @moduledoc false

  @diff_line_limit 40
  @diff_width_limit 180

  def write_if_changed!(path, contents) when is_binary(path) and is_binary(contents) do
    case File.read(path) do
      {:ok, ^contents} ->
        :unchanged

      {:ok, previous} ->
        File.write!(path, contents)
        report_update(path, previous, contents)
        :updated

      {:error, :enoent} ->
        File.write!(path, contents)
        Mix.shell().info("Created schema artifact: #{path} (#{byte_size(contents)} bytes)")
        :created

      {:error, reason} ->
        Mix.raise("could not read #{path}: #{:file.format_error(reason)}")
    end
  end

  defp report_update(path, previous, contents) do
    if Path.extname(path) == ".dot" do
      changes = changed_lines(previous, contents)
      added = Enum.count(changes, &match?({:add, _line}, &1))
      removed = Enum.count(changes, &match?({:remove, _line}, &1))

      Mix.shell().info("Updated schema artifact: #{path} (+#{added}/-#{removed} lines)")
      report_capped_diff(changes)
    else
      Mix.shell().info(
        "Updated schema artifact: #{path} " <>
          "(#{byte_size(previous)} → #{byte_size(contents)} bytes)"
      )
    end
  end

  defp changed_lines(previous, contents) do
    previous
    |> lines()
    |> List.myers_difference(lines(contents))
    |> Enum.flat_map(fn
      {:del, lines} -> Enum.map(lines, &{:remove, &1})
      {:ins, lines} -> Enum.map(lines, &{:add, &1})
      {:eq, _lines} -> []
    end)
  end

  defp lines(contents), do: String.split(contents, "\n", trim: false)

  defp report_capped_diff(changes) do
    shown = Enum.take(changes, @diff_line_limit)

    Mix.shell().info("Changed schema lines (capped at #{@diff_line_limit}):")

    Enum.each(shown, fn
      {:remove, line} -> Mix.shell().info("- " <> cap_line(line))
      {:add, line} -> Mix.shell().info("+ " <> cap_line(line))
    end)

    omitted = length(changes) - length(shown)
    if omitted > 0, do: Mix.shell().info("… #{omitted} additional changed lines omitted")
  end

  defp cap_line(line) do
    if String.length(line) > @diff_width_limit do
      String.slice(line, 0, @diff_width_limit) <> "…"
    else
      line
    end
  end
end
