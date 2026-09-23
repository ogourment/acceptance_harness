defmodule Mix.Tasks.Acceptance.StaleFiles do
  @moduledoc "Selects or records failed/new/modified ATDD scenario files."
  use Mix.Task

  alias AcceptanceHarness.StaleFiles

  @shortdoc "Selects stale ATDD scenario files"

  @impl Mix.Task
  def run(args) do
    {opts, positional, invalid} =
      OptionParser.parse(args,
        strict: [directory: :string, evidence: :string, manifest: :string, output: :string]
      )

    directory = opts[:directory]
    manifest = opts[:manifest]

    if invalid != [] or is_nil(directory) or is_nil(manifest) do
      usage!()
    end

    case positional do
      ["select"] ->
        if is_nil(opts[:evidence]), do: usage!()

        case StaleFiles.select(
               directory: directory,
               evidence_path: opts[:evidence],
               manifest_path: manifest
             ) do
          {:selected, paths} -> emit(paths, opts[:output])
          {:full, reason} -> emit(["__FULL__\t#{reason}"], opts[:output])
        end

      ["record-all"] ->
        StaleFiles.record_all!(directory, manifest)

      ["record-selected" | paths] when paths != [] ->
        StaleFiles.record_selected!(directory, manifest, paths)

      _other ->
        usage!()
    end
  end

  defp usage! do
    Mix.raise("""
    usage:
      mix acceptance.stale_files select --directory DIR --evidence FILE --manifest FILE
      mix acceptance.stale_files record-all --directory DIR --manifest FILE
      mix acceptance.stale_files record-selected PATH... --directory DIR --manifest FILE
    """)
  end

  defp emit(lines, nil), do: Enum.each(lines, fn line -> Mix.shell().info(line) end)

  defp emit(lines, path) do
    File.mkdir_p!(Path.dirname(Path.expand(path)))
    File.write!(path, Enum.join(lines, "\n") <> if(lines == [], do: "", else: "\n"))
  end
end
