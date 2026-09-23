defmodule AcceptanceHarness.Terminal.Evidence do
  @moduledoc "Persists a normalized terminal screen and its raw ANSI evidence."

  alias AcceptanceHarness.{Config, Evidence}
  alias AcceptanceHarness.Terminal.Screen

  @spec record_step!(Screen.t(), binary(), String.t(), String.t(), keyword()) :: :ok
  def record_step!(%Screen{} = screen, raw_ansi, title, description, options)
      when is_binary(raw_ansi) do
    artifact_name = Keyword.fetch!(options, :artifact_name)
    validate_artifact_name!(artifact_name)

    relative_base = Path.join("artifacts", artifact_name)
    ansi_path = relative_base <> ".ansi"
    text_path = relative_base <> ".txt"
    normalized = Screen.text(screen)

    write_artifact!(ansi_path, raw_ansi)
    write_artifact!(text_path, normalized)

    metadata =
      options
      |> Keyword.get(:metadata, %{})
      |> Map.put("surface", %{
        "kind" => "terminal",
        "text" => normalized,
        "columns" => screen.columns,
        "rows" => screen.rows
      })
      |> Map.put("artifacts", [
        %{"type" => "terminal_ansi", "path" => ansi_path, "label" => "Raw terminal output"},
        %{"type" => "terminal_text", "path" => text_path, "label" => "Normalized terminal screen"}
      ])

    Evidence.record_step("", title, description, metadata)
  end

  defp write_artifact!(relative_path, contents) do
    root = Path.expand(Config.evidence_dir())
    path = Path.expand(relative_path, root)
    ensure_within_root!(path, root)
    reject_symlink_components!(root, Path.relative_to(path, root))
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, contents)
  end

  defp ensure_within_root!(path, root) do
    unless path == root or String.starts_with?(path, root <> "/") do
      raise ArgumentError, "terminal artifact path must stay within the evidence directory"
    end
  end

  defp reject_symlink_components!(root, relative_path) do
    relative_path
    |> Path.split()
    |> Enum.reduce(root, fn component, parent ->
      candidate = Path.join(parent, component)

      case File.lstat(candidate) do
        {:ok, %File.Stat{type: :symlink}} ->
          raise ArgumentError, "terminal artifact path must not contain symlinks"

        _other ->
          candidate
      end
    end)

    :ok
  end

  defp validate_artifact_name!(name) when is_binary(name) and name != "" do
    if Path.type(name) == :relative and not Enum.member?(Path.split(name), "..") do
      :ok
    else
      raise ArgumentError, "terminal artifact_name must be a safe relative path"
    end
  end

  defp validate_artifact_name!(_name),
    do: raise(ArgumentError, "terminal artifact_name must be a non-empty relative path")
end
