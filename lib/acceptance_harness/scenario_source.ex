defmodule AcceptanceHarness.ScenarioSource do
  @moduledoc false

  def read(%{} = metadata) do
    source_file = metadata["source_path"] || metadata["source_file"]
    source_test = metadata["source_test"]

    cond do
      not is_binary(source_file) or not File.regular?(source_file) ->
        :error

      is_binary(source_test) and source_test != "" ->
        read_elixir_test!(source_file, source_test)

      true ->
        {:ok, File.read!(source_file), extension(source_file)}
    end
  end

  defp read_elixir_test!(source_file, source_test) do
    unless Path.extname(source_file) in [".ex", ".exs"] do
      raise ArgumentError,
            "source_test requires an Elixir .ex or .exs source file, got: #{source_file}"
    end

    contents = File.read!(source_file)

    ast =
      case Code.string_to_quoted(contents, columns: true, token_metadata: true) do
        {:ok, ast} ->
          ast

        {:error, error} ->
          raise ArgumentError, "could not parse scenario source #{source_file}: #{inspect(error)}"
      end

    {_ast, matches} =
      Macro.prewalk(ast, [], fn
        {:test, metadata, [^source_test | _rest]} = node, matches ->
          {node, [metadata | matches]}

        node, matches ->
          {node, matches}
      end)

    case matches do
      [metadata] ->
        start_line = Keyword.fetch!(metadata, :line)
        end_line = metadata |> Keyword.fetch!(:end) |> Keyword.fetch!(:line)
        lines = String.split(contents, "\n", trim: false)
        block = lines |> Enum.slice((start_line - 1)..(end_line - 1)) |> Enum.join("\n")
        {:ok, block <> "\n", extension(source_file)}

      [] ->
        raise ArgumentError,
              "could not find Elixir test #{inspect(source_test)} in scenario source #{source_file}"

      _matches ->
        raise ArgumentError,
              "found more than one Elixir test #{inspect(source_test)} in scenario source #{source_file}"
    end
  end

  defp extension(source_file) do
    case Path.extname(source_file) do
      "" -> ".txt"
      extension -> extension
    end
  end
end
