defmodule AcceptanceHarness.StaleFiles do
  @moduledoc """
  Selects failed, new, and modified ATDD scenario files from durable hashes.

  Selection is deliberately conservative: missing or corrupt evidence or a
  missing/incompatible manifest requests a full run.
  """

  @manifest_version 1
  @scenario_pattern ~r/Suite\.scenario!?\(\s*["']([^"']+)["']\s*\)/

  def select(opts) do
    directory = opts |> Keyword.fetch!(:directory) |> Path.expand()
    evidence_path = opts |> Keyword.fetch!(:evidence_path) |> Path.expand()
    manifest_path = opts |> Keyword.fetch!(:manifest_path) |> Path.expand()
    files = scan(directory)

    with {:ok, manifest} <- read_manifest(manifest_path),
         :ok <- ensure_no_deleted_files(manifest, files),
         {:ok, failed_ids} <- failed_ids(evidence_path),
         {:ok, failed_files} <- files_for_ids(files, failed_ids) do
      changed_files =
        files
        |> Enum.filter(fn {path, metadata} -> manifest[path] != metadata.checksum end)
        |> Enum.map(&elem(&1, 0))

      {:selected, Enum.sort(Enum.uniq(failed_files ++ changed_files))}
    else
      {:error, reason} -> {:full, reason}
    end
  end

  def record_all!(directory, manifest_path) do
    directory
    |> Path.expand()
    |> scan()
    |> hashes()
    |> write_manifest!(manifest_path)
  end

  def record_selected!(directory, manifest_path, selected_paths) do
    directory = Path.expand(directory)

    with {:ok, manifest} <- read_manifest(Path.expand(manifest_path)) do
      current = scan(directory)

      selected =
        selected_paths
        |> Enum.map(&Path.expand/1)
        |> MapSet.new()

      updated =
        Enum.reduce(current, manifest, fn {path, metadata}, hashes ->
          if MapSet.member?(selected, path) do
            Map.put(hashes, path, metadata.checksum)
          else
            hashes
          end
        end)

      write_manifest!(updated, manifest_path)
    else
      {:error, reason} -> raise ArgumentError, reason
    end
  end

  def scan(directory) do
    directory
    |> Path.join("**/*_atdd_test.exs")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.sort()
    |> Map.new(fn path ->
      body = File.read!(path)

      ids =
        @scenario_pattern
        |> Regex.scan(body, capture: :all_but_first)
        |> List.flatten()
        |> Enum.uniq()

      {Path.expand(path), %{checksum: checksum(body), scenario_ids: ids}}
    end)
  end

  defp failed_ids(path) do
    with {:ok, body} <- File.read(path),
         {:ok, evidence} <- Jason.decode(body),
         true <- get_in(evidence, ["timing", "finalized"]) == true,
         finalized_at when is_binary(finalized_at) <- get_in(evidence, ["run", "finalized_at"]),
         scenarios when is_list(scenarios) <- evidence["scenarios"],
         true <- Enum.all?(scenarios, &valid_scenario?/1) do
      ids =
        scenarios
        |> Enum.reject(&(&1["status"] == "success"))
        |> Enum.map(& &1["id"])

      {:ok, ids}
    else
      {:error, :enoent} -> {:error, "last finalized ATDD evidence is missing"}
      _error -> {:error, "last finalized ATDD evidence is corrupt or incomplete"}
    end
  end

  defp valid_scenario?(%{"id" => id, "status" => status})
       when is_binary(id) and status in ["success", "failure", "not_run"],
       do: true

  defp valid_scenario?(_scenario), do: false

  defp files_for_ids(files, ids) do
    by_id =
      Enum.reduce(files, %{}, fn {path, metadata}, index ->
        Enum.reduce(metadata.scenario_ids, index, fn id, acc ->
          Map.update(acc, id, [path], &[path | &1])
        end)
      end)

    missing = Enum.reject(ids, &Map.has_key?(by_id, &1))

    if missing == [] do
      {:ok, ids |> Enum.flat_map(&Map.fetch!(by_id, &1)) |> Enum.uniq()}
    else
      {:error,
       "failed scenario IDs could not be mapped to source files: #{Enum.join(missing, ", ")}"}
    end
  end

  defp read_manifest(path) do
    with {:ok, body} <- File.read(path),
         {:ok, %{"version" => @manifest_version, "files" => files}} when is_map(files) <-
           Jason.decode(body),
         true <- Enum.all?(files, fn {path, hash} -> valid_hash?(path, hash) end) do
      {:ok, files}
    else
      {:error, :enoent} -> {:error, "ATDD stale manifest is missing"}
      _error -> {:error, "ATDD stale manifest is corrupt or incompatible"}
    end
  end

  defp ensure_no_deleted_files(manifest, files) do
    case Map.keys(manifest) -- Map.keys(files) do
      [] -> :ok
      _deleted -> {:error, "an ATDD scenario file recorded in the manifest was deleted"}
    end
  end

  defp hashes(files), do: Map.new(files, fn {path, metadata} -> {path, metadata.checksum} end)

  defp write_manifest!(files, path) do
    path = Path.expand(path)
    File.mkdir_p!(Path.dirname(path))

    payload = %{
      "version" => @manifest_version,
      "files" => files,
      "updated_at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
    }

    File.write!(path, Jason.encode!(payload, pretty: true))
    :ok
  end

  defp valid_hash?(path, hash) do
    is_binary(path) and Path.type(path) == :absolute and is_binary(hash) and
      String.match?(hash, ~r/\A[0-9a-f]{64}\z/)
  end

  defp checksum(body) do
    body |> then(&:crypto.hash(:sha256, &1)) |> Base.encode16(case: :lower)
  end
end
