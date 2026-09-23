defmodule AcceptanceHarness.SourceDiff do
  @moduledoc false

  @context_lines 3

  def compare(previous, current) when is_binary(previous) and is_binary(current) do
    rows =
      previous
      |> lines()
      |> List.myers_difference(lines(current))
      |> diff_rows()

    %{
      additions: Enum.count(rows, &(&1.kind == :added)),
      deletions: Enum.count(rows, &(&1.kind == :removed)),
      rows: contextual_rows(rows)
    }
  end

  defp lines(contents), do: String.split(contents, "\n", trim: false)

  defp diff_rows(changes) do
    {rows, _old_line, _new_line} =
      Enum.reduce(changes, {[], 1, 1}, fn
        {:eq, lines}, {rows, old_line, new_line} ->
          additions =
            Enum.with_index(lines)
            |> Enum.map(fn {text, offset} ->
              %{
                kind: :context,
                old_line: old_line + offset,
                new_line: new_line + offset,
                text: text
              }
            end)

          {rows ++ additions, old_line + length(lines), new_line + length(lines)}

        {:del, lines}, {rows, old_line, new_line} ->
          removals =
            Enum.with_index(lines)
            |> Enum.map(fn {text, offset} ->
              %{kind: :removed, old_line: old_line + offset, new_line: nil, text: text}
            end)

          {rows ++ removals, old_line + length(lines), new_line}

        {:ins, lines}, {rows, old_line, new_line} ->
          additions =
            Enum.with_index(lines)
            |> Enum.map(fn {text, offset} ->
              %{kind: :added, old_line: nil, new_line: new_line + offset, text: text}
            end)

          {rows ++ additions, old_line, new_line + length(lines)}
      end)

    rows
  end

  defp contextual_rows(rows) do
    changed_indexes =
      rows
      |> Enum.with_index()
      |> Enum.filter(fn {row, _index} -> row.kind != :context end)
      |> Enum.map(&elem(&1, 1))

    visible =
      Enum.reduce(changed_indexes, MapSet.new(), fn index, indexes ->
        Enum.reduce((index - @context_lines)..(index + @context_lines), indexes, fn candidate,
                                                                                    acc ->
          if candidate >= 0 and candidate < length(rows),
            do: MapSet.put(acc, candidate),
            else: acc
        end)
      end)

    rows
    |> Enum.with_index()
    |> Enum.filter(fn {_row, index} -> MapSet.member?(visible, index) end)
    |> Enum.chunk_by(fn {_row, index} -> index end)
    |> Enum.flat_map(& &1)
    |> insert_omissions()
    |> Enum.map(&elem(&1, 0))
  end

  defp insert_omissions([]), do: []

  defp insert_omissions([first | rest]) do
    {result, _previous_index} =
      Enum.reduce(rest, {[first], elem(first, 1)}, fn {_row, index} = item,
                                                      {items, previous_index} ->
        items =
          if index > previous_index + 1 do
            items ++ [{%{kind: :omitted, old_line: nil, new_line: nil, text: "…"}, index - 1}]
          else
            items
          end

        {items ++ [item], index}
      end)

    result
  end
end
