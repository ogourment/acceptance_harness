defmodule AcceptanceHarness.EvidenceRetention do
  @moduledoc """
  Plans and applies bounded retention for locally stored acceptance screenshots.

  Run rows remain owned by `AcceptanceHarness.AdminStore`. This module only
  changes files below each run's evidence directory, so scenario, step, and run
  metadata remain queryable after screenshot data is removed.

  The default policy keeps full screenshots for every run for three days, then
  for the newest run in each UTC day through three weeks, ISO week through
  three months, and calendar month through three years. Other runs retain
  pre-generated thumbnails while their full screenshots are removed. If
  `:max_bytes` is set, the oldest archived thumbnails are removed until the
  local screenshot total fits the cap.

  `apply/2` requires an explicit `:root`. A run whose source directory is
  outside that root is skipped by default, while symlinked paths are rejected.
  """

  @archive_marker ".acceptance-harness-screenshots-archived"
  @default_thumbnail_geometry "480x480>"

  @type run :: map()
  @type decision :: %{run: run(), captured_at: DateTime.t(), action: :keep_full | :archive}

  @defaults [full_days: 3, daily_days: 21, weekly_days: 90, monthly_days: 1_095]

  @doc "Returns the tiered retention decision for each run, newest first."
  @spec plan([run()], keyword()) :: [decision()]
  def plan(runs, opts \\ []) when is_list(runs) do
    now = Keyword.get(opts, :now, DateTime.utc_now())
    config = config!(opts)

    runs
    |> Enum.map(fn run -> %{run: run, captured_at: captured_at!(run)} end)
    |> Enum.sort_by(& &1.captured_at, {:desc, DateTime})
    |> decide(now, config)
  end

  @doc """
  Applies the retention plan and returns an audit-friendly summary.

  The optional `:thumbnailer` receives `(source_path, temporary_path,
  geometry)`. The default invokes ImageMagick without a shell. Consumers can
  inject an image-library callback instead.
  """
  @spec apply([run()], keyword()) :: {:ok, map()} | {:error, term()}
  def apply(runs, opts) when is_list(runs) and is_list(opts) do
    root = opts |> Keyword.fetch!(:root) |> Path.expand()
    decisions = plan(runs, opts)

    :global.trans({__MODULE__, root}, fn ->
      with :ok <- validate_root(root),
           {:ok, locations, skipped} <- validate_locations(decisions, root, opts),
           {:ok, orphans, orphan_skipped} <- scan_orphans(root, runs, opts),
           {:ok, pruned_payloads} <- prune_payloads(locations, opts),
           {:ok, archived, archive_skipped} <- archive_selected(locations, opts),
           {:ok, capacity} <- enforce_capacity(locations, orphans, opts) do
        {:ok,
         %{
           decisions: Enum.map(locations, &Map.take(&1, [:id, :captured_at, :action])),
           skipped: skipped,
           pruned_payloads: pruned_payloads,
           archived: archived,
           archive_skipped: archive_skipped ++ capacity.archive_skipped,
           forced_archived: capacity.forced_archived,
           deleted: capacity.deleted,
           orphan_snapshots: Enum.map(orphans, & &1.name),
           orphan_skipped: orphan_skipped,
           deleted_orphans: capacity.deleted_orphans,
           bytes: capacity.bytes,
           max_bytes: capacity.max_bytes,
           over_limit_bytes: capacity.over_limit_bytes
         }}
      end
    end)
  end

  defp decide(entries, now, config) do
    {decisions, _buckets} =
      Enum.map_reduce(entries, MapSet.new(), fn entry, buckets ->
        age_days = max(DateTime.diff(now, entry.captured_at, :second), 0) / 86_400
        tier = tier(age_days, config)
        bucket = bucket(tier, entry.captured_at)
        keep? = tier == :full or (bucket && not MapSet.member?(buckets, bucket))
        buckets = if keep? && bucket, do: MapSet.put(buckets, bucket), else: buckets

        {Map.put(entry, :action, if(keep?, do: :keep_full, else: :archive)), buckets}
      end)

    decisions
  end

  defp tier(age_days, config) when age_days <= config.full_days, do: :full
  defp tier(age_days, config) when age_days <= config.daily_days, do: :daily
  defp tier(age_days, config) when age_days <= config.weekly_days, do: :weekly
  defp tier(age_days, config) when age_days <= config.monthly_days, do: :monthly
  defp tier(_age_days, _config), do: :expired

  defp bucket(:full, _captured_at), do: nil
  defp bucket(:daily, captured_at), do: {:day, DateTime.to_date(captured_at)}

  defp bucket(:weekly, captured_at) do
    date = DateTime.to_date(captured_at)
    {year, week} = :calendar.iso_week_number({date.year, date.month, date.day})
    {:week, year, week}
  end

  defp bucket(:monthly, captured_at), do: {:month, captured_at.year, captured_at.month}
  defp bucket(:expired, _captured_at), do: nil

  defp config!(opts) do
    config = Map.new(@defaults, fn {key, default} -> {key, Keyword.get(opts, key, default)} end)

    unless Enum.all?(config, fn {_key, value} -> is_integer(value) and value >= 0 end) and
             config.full_days <= config.daily_days and
             config.daily_days <= config.weekly_days and
             config.weekly_days <= config.monthly_days do
      raise ArgumentError,
            "retention days must be non-negative and ordered full <= daily <= weekly <= monthly"
    end

    config
  end

  defp captured_at!(run) do
    value = value(run, :finalized_at) || value(run, :generated_at) || value(run, :inserted_at)

    case value do
      %DateTime{} = datetime ->
        datetime

      %NaiveDateTime{} = datetime ->
        DateTime.from_naive!(datetime, "Etc/UTC")

      binary when is_binary(binary) ->
        case DateTime.from_iso8601(binary) do
          {:ok, datetime, _offset} -> datetime
          _ -> raise ArgumentError, "invalid run timestamp: #{inspect(binary)}"
        end

      _ ->
        raise ArgumentError, "run #{inspect(value(run, :id))} has no retention timestamp"
    end
  end

  defp validate_root(root) do
    if root == "/" do
      {:error, {:unsafe_root, root}}
    else
      case File.lstat(root) do
        {:ok, %File.Stat{type: :directory}} -> :ok
        {:ok, %File.Stat{type: :symlink}} -> {:error, {:unsafe_symlink, root}}
        {:ok, _stat} -> {:error, {:not_a_directory, root}}
        {:error, reason} -> {:error, {:invalid_root, root, reason}}
      end
    end
  end

  defp validate_locations(decisions, root, opts) do
    skip_unmanaged? = Keyword.get(opts, :skip_unmanaged, true)

    Enum.reduce_while(decisions, {:ok, [], []}, fn decision, {:ok, locations, skipped} ->
      with {:ok, location} <- validate_location(decision, root) do
        {:cont, {:ok, [location | locations], skipped}}
      else
        {:error, {:missing_source_dir, id} = reason} ->
          {:cont, {:ok, locations, [%{run_id: id, reason: reason} | skipped]}}

        {:error, {:missing_directory, id, _path} = reason} ->
          {:cont, {:ok, locations, [%{run_id: id, reason: reason} | skipped]}}

        {:error, {:outside_root, id, _path} = reason} when skip_unmanaged? ->
          {:cont, {:ok, locations, [%{run_id: id, reason: reason} | skipped]}}

        {:error, reason} ->
          {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, locations, skipped} -> {:ok, Enum.reverse(locations), Enum.reverse(skipped)}
      error -> error
    end
  end

  defp validate_location(decision, root) do
    run = decision.run
    id = value(run, :id) || raise ArgumentError, "retention run has no id"
    source_dir = value(run, :source_dir)

    if not is_binary(source_dir) or source_dir == "" do
      {:error, {:missing_source_dir, id}}
    else
      source_dir = Path.expand(source_dir)
      screenshots_dir = Path.join(source_dir, "screenshots")
      thumbnails_dir = Path.join(source_dir, "thumbnails")

      with true <- inside?(source_dir, root) || {:error, {:outside_root, id, source_dir}},
           :ok <- ordinary_ancestry(source_dir, root, id),
           :ok <- ordinary_directory(screenshots_dir, id) do
        {:ok,
         decision
         |> Map.drop([:run])
         |> Map.merge(%{
           id: id,
           source_dir: source_dir,
           screenshots_dir: screenshots_dir,
           thumbnails_dir: thumbnails_dir
         })}
      end
    end
  end

  defp ordinary_ancestry(path, root, id) do
    path
    |> Path.relative_to(root)
    |> Path.split()
    |> Enum.reduce_while({:ok, root}, fn component, {:ok, parent} ->
      current = Path.join(parent, component)

      case ordinary_directory(current, id) do
        :ok -> {:cont, {:ok, current}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, _path} -> :ok
      error -> error
    end
  end

  defp ordinary_directory(path, id) do
    case File.lstat(path) do
      {:ok, %File.Stat{type: :directory}} -> :ok
      {:ok, %File.Stat{type: :symlink}} -> {:error, {:unsafe_symlink, id, path}}
      {:ok, _stat} -> {:error, {:not_a_directory, id, path}}
      {:error, :enoent} -> {:error, {:missing_directory, id, path}}
      {:error, reason} -> {:error, {:invalid_directory, id, path, reason}}
    end
  end

  defp inside?(path, root), do: path != root and String.starts_with?(path, root <> "/")

  defp scan_orphans(root, runs, opts) do
    case Keyword.get(opts, :snapshot_prefix) do
      nil ->
        {:ok, [], []}

      prefix when is_binary(prefix) and prefix != "" ->
        if Path.basename(prefix) != prefix do
          raise ArgumentError, ":snapshot_prefix must be a basename prefix"
        end

        referenced =
          runs
          |> Enum.map(&value(&1, :source_dir))
          |> Enum.filter(&is_binary/1)
          |> Enum.map(&Path.expand/1)
          |> MapSet.new()

        current_protected = current_snapshot_paths(root, opts)
        grace_seconds = Keyword.get(opts, :orphan_grace_seconds, 86_400)

        unless is_integer(grace_seconds) and grace_seconds >= 0 do
          raise ArgumentError, ":orphan_grace_seconds must be a non-negative integer"
        end

        now_seconds = opts |> Keyword.get(:now, DateTime.utc_now()) |> DateTime.to_unix()
        marker = Keyword.get(opts, :in_progress_marker, ".in-progress")

        unless is_binary(marker) and marker != "" and Path.basename(marker) == marker do
          raise ArgumentError, ":in_progress_marker must be a basename"
        end

        root
        |> File.ls()
        |> case do
          {:ok, names} ->
            names
            |> Enum.filter(&String.starts_with?(&1, prefix))
            |> Enum.sort()
            |> Enum.reduce({[], []}, fn name, {orphans, skipped} ->
              path = Path.join(root, name)

              case orphan_location(
                     path,
                     name,
                     referenced,
                     current_protected,
                     marker,
                     now_seconds,
                     grace_seconds
                   ) do
                {:ok, orphan} ->
                  {[orphan | orphans], skipped}

                {:protect, orphan, reason} ->
                  {[orphan | orphans], [%{name: name, reason: reason} | skipped]}

                {:skip, reason} ->
                  {orphans, [%{name: name, reason: reason} | skipped]}
              end
            end)
            |> then(fn {orphans, skipped} ->
              {:ok, Enum.reverse(orphans), Enum.reverse(skipped)}
            end)

          {:error, reason} ->
            {:error, {:scan_root_failed, root, reason}}
        end

      _ ->
        raise ArgumentError, ":snapshot_prefix must be nil or a non-empty basename prefix"
    end
  end

  defp current_snapshot_paths(root, opts) do
    current_name = Keyword.get(opts, :current_name, "current")

    unless is_binary(current_name) and current_name != "" and
             Path.basename(current_name) == current_name do
      raise ArgumentError, ":current_name must be a basename"
    end

    current_path = Path.join(root, current_name)
    protected = MapSet.new([current_path])

    case File.read_link(current_path) do
      {:ok, target} ->
        target =
          if Path.type(target) == :absolute,
            do: Path.expand(target),
            else: Path.expand(target, root)

        if inside?(target, root), do: MapSet.put(protected, target), else: protected

      {:error, _reason} ->
        protected
    end
  end

  defp orphan_location(
         path,
         name,
         referenced,
         current_protected,
         marker,
         now_seconds,
         grace_seconds
       ) do
    case File.lstat(path, time: :posix) do
      {:ok, %File.Stat{type: :symlink}} ->
        {:skip, :symlink}

      {:ok, %File.Stat{type: :directory, mtime: mtime}} ->
        orphan = %{
          name: name,
          path: path,
          captured_at: DateTime.from_unix!(mtime),
          screenshots_dir: Path.join(path, "screenshots"),
          thumbnails_dir: Path.join(path, "thumbnails"),
          deletable?: true
        }

        cond do
          MapSet.member?(referenced, path) ->
            {:skip, :referenced}

          MapSet.member?(current_protected, path) ->
            {:protect, %{orphan | deletable?: false}, :current}

          match?({:ok, _stat}, File.lstat(Path.join(path, marker))) ->
            {:protect, %{orphan | deletable?: false}, :in_progress}

          now_seconds - mtime < grace_seconds ->
            {:protect, %{orphan | deletable?: false}, :grace_period}

          true ->
            {:ok, orphan}
        end

      {:ok, _stat} ->
        {:skip, :not_a_directory}

      {:error, reason} ->
        {:skip, {:stat_failed, reason}}
    end
  end

  defp archive_selected(locations, opts) do
    locations
    |> Enum.filter(&(&1.action == :archive))
    |> Enum.reduce_while({:ok, [], []}, fn location, {:ok, archived, skipped} ->
      case archive(location, opts) do
        {:ok, :already_archived} ->
          {:cont, {:ok, archived, skipped}}

        {:ok, :archived} ->
          {:cont, {:ok, [location.id | archived], skipped}}

        {:error, {:missing_thumbnail, _source, _thumbnail} = reason} ->
          {:cont, {:ok, archived, [%{run_id: location.id, reason: reason} | skipped]}}

        {:error, reason} ->
          {:halt, {:error, {:archive_failed, location.id, reason}}}
      end
    end)
    |> case do
      {:ok, archived, skipped} -> {:ok, Enum.reverse(archived), Enum.reverse(skipped)}
      error -> error
    end
  end

  defp prune_payloads(locations, opts) do
    names = Keyword.get(opts, :prune_payload_names, [])

    unless is_list(names) and
             Enum.all?(names, fn name ->
               is_binary(name) and name != "" and Path.basename(name) == name and
                 name not in ["screenshots", @archive_marker]
             end) do
      raise ArgumentError, ":prune_payload_names must contain safe basenames"
    end

    Enum.reduce_while(locations, {:ok, []}, fn location, {:ok, pruned} ->
      Enum.reduce_while(names, {:ok, pruned}, fn name, {:ok, pruned} ->
        path = Path.join(location.source_dir, name)

        case File.lstat(path) do
          {:ok, %File.Stat{type: :regular}} ->
            case File.rm(path) do
              :ok ->
                {:cont, {:ok, [%{run_id: location.id, name: name} | pruned]}}

              {:error, reason} ->
                {:halt, {:error, {:remove_payload_failed, location.id, name, reason}}}
            end

          {:ok, %File.Stat{type: :symlink}} ->
            {:halt, {:error, {:unsafe_payload_symlink, location.id, name}}}

          {:ok, _stat} ->
            {:halt, {:error, {:unsafe_payload_type, location.id, name}}}

          {:error, :enoent} ->
            {:cont, {:ok, pruned}}

          {:error, reason} ->
            {:halt, {:error, {:payload_stat_failed, location.id, name, reason}}}
        end
      end)
      |> case do
        {:ok, pruned} -> {:cont, {:ok, pruned}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
    |> case do
      {:ok, pruned} -> {:ok, Enum.reverse(pruned)}
      error -> error
    end
  end

  defp archive(location, opts) do
    marker = Path.join(location.source_dir, @archive_marker)

    if File.regular?(marker) do
      {:ok, :already_archived}
    else
      thumbnailer =
        Keyword.get(opts, :thumbnailer) ||
          if(Keyword.get(opts, :generate_missing_thumbnails, false),
            do: &imagemagick_thumbnail/3
          )

      geometry = Keyword.get(opts, :thumbnail_geometry, @default_thumbnail_geometry)

      with {:ok, files} <- screenshot_files(location.screenshots_dir),
           :ok <- File.mkdir_p(location.thumbnails_dir),
           {:ok, thumbnails} <-
             ensure_thumbnails(files, location.thumbnails_dir, thumbnailer, geometry),
           :ok <- verify_regular_files(thumbnails),
           :ok <- delete_files(files),
           :ok <- File.write(marker, "archived\n", [:exclusive]) do
        {:ok, :archived}
      else
        {:error, :eexist} -> {:ok, :already_archived}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp screenshot_files(directory) do
    regular_files(directory, false)
  end

  defp thumbnail_files(directory) do
    regular_files(directory, true)
  end

  defp regular_files(directory, missing_ok?) do
    directory
    |> File.ls()
    |> case do
      {:ok, names} ->
        names
        |> Enum.sort()
        |> Enum.reduce_while({:ok, []}, fn name, {:ok, files} ->
          path = Path.join(directory, name)

          case File.lstat(path) do
            {:ok, %File.Stat{type: :regular}} -> {:cont, {:ok, [path | files]}}
            {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, {:unsafe_symlink, path}}}
            {:ok, _stat} -> {:cont, {:ok, files}}
            {:error, reason} -> {:halt, {:error, {:stat_failed, path, reason}}}
          end
        end)
        |> then(fn
          {:ok, files} -> {:ok, Enum.reverse(files)}
          error -> error
        end)

      {:error, reason} ->
        if missing_ok? and reason == :enoent,
          do: {:ok, []},
          else: {:error, {:list_failed, directory, reason}}
    end
  end

  defp ensure_thumbnails(files, directory, thumbnailer, geometry) do
    result =
      Enum.reduce_while(files, {:ok, []}, fn source, {:ok, replacements} ->
        thumbnail = Path.join(directory, Path.rootname(Path.basename(source)) <> ".webp")

        cond do
          File.regular?(thumbnail) ->
            {:cont, {:ok, [thumbnail | replacements]}}

          is_function(thumbnailer, 3) ->
            temporary = thumbnail <> ".retention-#{System.unique_integer([:positive])}.webp"

            case thumbnailer.(source, temporary, geometry) do
              :ok ->
                case File.rename(temporary, thumbnail) do
                  :ok ->
                    {:cont, {:ok, [thumbnail | replacements]}}

                  {:error, reason} ->
                    {:halt, {:error, {:replace_failed, thumbnail, reason}, replacements}}
                end

              {:error, reason} ->
                {:halt, {:error, {:thumbnail_failed, source, reason}, replacements}}

              other ->
                {:halt, {:error, {:invalid_thumbnailer_result, source, other}, replacements}}
            end

          true ->
            {:halt, {:error, {:missing_thumbnail, source, thumbnail}, replacements}}
        end
      end)

    case result do
      {:ok, thumbnails} ->
        {:ok, Enum.reverse(thumbnails)}

      {:error, reason, _thumbnails} ->
        {:error, reason}
    end
  end

  defp verify_regular_files(files) do
    Enum.reduce_while(files, :ok, fn path, :ok ->
      case File.lstat(path) do
        {:ok, %File.Stat{type: :regular, size: size}} when size > 0 -> {:cont, :ok}
        {:ok, %File.Stat{type: :symlink}} -> {:halt, {:error, {:unsafe_symlink, path}}}
        {:ok, _stat} -> {:halt, {:error, {:invalid_thumbnail, path}}}
        {:error, reason} -> {:halt, {:error, {:stat_failed, path, reason}}}
      end
    end)
  end

  defp imagemagick_thumbnail(source, temporary, geometry) do
    executable = System.find_executable("magick") || System.find_executable("convert")

    if executable do
      case System.cmd(executable, [source, "-thumbnail", geometry, "-strip", temporary],
             stderr_to_stdout: true
           ) do
        {_output, 0} -> :ok
        {output, status} -> {:error, {:imagemagick, status, String.trim(output)}}
      end
    else
      {:error, :imagemagick_not_found}
    end
  end

  defp enforce_capacity(locations, orphans, opts) do
    max_bytes = Keyword.get(opts, :max_bytes)

    unless is_nil(max_bytes) or (is_integer(max_bytes) and max_bytes >= 0) do
      raise ArgumentError, ":max_bytes must be a non-negative integer or nil"
    end

    with {:ok, initial_bytes} <- total_bytes(locations, orphans),
         {:ok, after_orphans, deleted_orphans, remaining_orphans} <-
           delete_orphans_to_limit(locations, orphans, initial_bytes, max_bytes),
         {:ok, after_archive, forced_archived, archive_skipped} <-
           force_archive_to_limit(
             locations,
             remaining_orphans,
             after_orphans,
             max_bytes,
             opts
           ) do
      delete_to_limit(
        locations,
        remaining_orphans,
        after_archive,
        max_bytes,
        forced_archived,
        archive_skipped,
        deleted_orphans
      )
    end
  end

  defp delete_orphans_to_limit(_locations, orphans, bytes, nil),
    do: {:ok, bytes, [], orphans}

  defp delete_orphans_to_limit(locations, orphans, bytes, max_bytes) do
    orphans
    |> Enum.filter(& &1.deletable?)
    |> Enum.sort_by(& &1.captured_at, DateTime)
    |> Enum.reduce_while({:ok, bytes, []}, fn orphan, {:ok, current_bytes, deleted} ->
      if current_bytes <= max_bytes do
        {:halt, {:ok, current_bytes, deleted}}
      else
        case delete_orphan(orphan) do
          :ok ->
            remaining = Enum.reject(orphans, &(&1.path == orphan.path))

            case total_bytes(locations, remaining) do
              {:ok, remaining_bytes} ->
                {:cont, {:ok, remaining_bytes, [orphan.name | deleted]}}

              {:error, reason} ->
                {:halt, {:error, {:orphan_size_failed, orphan.name, reason}}}
            end

          {:error, reason} ->
            {:halt, {:error, {:orphan_delete_failed, orphan.name, reason}}}
        end
      end
    end)
    |> case do
      {:ok, final_bytes, deleted} ->
        deleted = Enum.reverse(deleted)
        remaining = Enum.reject(orphans, &(&1.name in deleted))
        {:ok, final_bytes, deleted, remaining}

      error ->
        error
    end
  end

  defp delete_orphan(orphan) do
    with :ok <- reject_symlinks(orphan.path),
         {:ok, entries} <- File.ls(orphan.path),
         :ok <- delete_tree_entries(orphan.path, entries),
         :ok <- File.rmdir(orphan.path) do
      :ok
    end
  end

  defp reject_symlinks(path) do
    with {:ok, entries} <- File.ls(path) do
      Enum.reduce_while(entries, :ok, fn name, :ok ->
        child = Path.join(path, name)

        case File.lstat(child) do
          {:ok, %File.Stat{type: :symlink}} ->
            {:halt, {:error, {:unsafe_symlink, child}}}

          {:ok, %File.Stat{type: :directory}} ->
            case reject_symlinks(child) do
              :ok -> {:cont, :ok}
              {:error, reason} -> {:halt, {:error, reason}}
            end

          {:ok, _stat} ->
            {:cont, :ok}

          {:error, reason} ->
            {:halt, {:error, {:stat_failed, child, reason}}}
        end
      end)
    end
  end

  defp delete_tree_entries(parent, entries) do
    Enum.reduce_while(entries, :ok, fn name, :ok ->
      path = Path.join(parent, name)

      case File.lstat(path) do
        {:ok, %File.Stat{type: :directory}} ->
          with {:ok, children} <- File.ls(path),
               :ok <- delete_tree_entries(path, children),
               :ok <- File.rmdir(path) do
            {:cont, :ok}
          else
            {:error, reason} -> {:halt, {:error, {:remove_failed, path, reason}}}
          end

        {:ok, %File.Stat{type: :regular}} ->
          case File.rm(path) do
            :ok -> {:cont, :ok}
            {:error, reason} -> {:halt, {:error, {:remove_failed, path, reason}}}
          end

        {:ok, %File.Stat{type: :symlink}} ->
          {:halt, {:error, {:unsafe_symlink, path}}}

        {:ok, _stat} ->
          {:halt, {:error, {:unsafe_file_type, path}}}

        {:error, reason} ->
          {:halt, {:error, {:stat_failed, path, reason}}}
      end
    end)
  end

  defp force_archive_to_limit(_locations, _orphans, bytes, nil, _opts),
    do: {:ok, bytes, [], []}

  defp force_archive_to_limit(locations, orphans, bytes, max_bytes, opts) do
    newest_id = locations |> List.first() |> then(&(&1 && &1.id))

    locations
    |> Enum.filter(&(&1.action == :keep_full and &1.id != newest_id))
    |> Enum.sort_by(& &1.captured_at, DateTime)
    |> Enum.reduce_while({:ok, bytes, [], []}, fn location,
                                                  {:ok, current_bytes, archived, skipped} ->
      if current_bytes <= max_bytes do
        {:halt, {:ok, current_bytes, archived, skipped}}
      else
        case archive(location, opts) do
          {:ok, _state} ->
            case total_bytes(locations, orphans) do
              {:ok, remaining_bytes} ->
                {:cont, {:ok, remaining_bytes, [location.id | archived], skipped}}

              {:error, reason} ->
                {:halt, {:error, {:size_failed_after_archive, location.id, reason}}}
            end

          {:error, {:missing_thumbnail, _source, _thumbnail} = reason} ->
            {:cont,
             {:ok, current_bytes, archived, [%{run_id: location.id, reason: reason} | skipped]}}

          {:error, reason} ->
            {:halt, {:error, {:capacity_archive_failed, location.id, reason}}}
        end
      end
    end)
    |> case do
      {:ok, final_bytes, archived, skipped} ->
        {:ok, final_bytes, Enum.reverse(archived), Enum.reverse(skipped)}

      error ->
        error
    end
  end

  defp delete_to_limit(
         _locations,
         _orphans,
         bytes,
         nil,
         forced_archived,
         archive_skipped,
         deleted_orphans
       ) do
    {:ok,
     %{
       deleted: [],
       forced_archived: forced_archived,
       archive_skipped: archive_skipped,
       deleted_orphans: deleted_orphans,
       bytes: bytes,
       max_bytes: nil,
       over_limit_bytes: 0
     }}
  end

  defp delete_to_limit(
         locations,
         orphans,
         bytes,
         max_bytes,
         forced_archived,
         archive_skipped,
         deleted_orphans
       ) do
    newest_id = locations |> List.first() |> then(&(&1 && &1.id))

    candidates =
      locations
      |> Enum.reject(&(&1.id == newest_id))
      |> Enum.sort_by(& &1.captured_at, DateTime)

    candidates
    |> Enum.reduce_while({:ok, bytes, []}, fn location, {:ok, current_bytes, deleted} ->
      if current_bytes <= max_bytes do
        {:halt, {:ok, current_bytes, deleted}}
      else
        with {:ok, files} <- thumbnail_files(location.thumbnails_dir) do
          if files == [] do
            {:cont, {:ok, current_bytes, deleted}}
          else
            with :ok <- delete_files(files),
                 {:ok, remaining_bytes} <- total_bytes(locations, orphans) do
              {:cont, {:ok, remaining_bytes, [location.id | deleted]}}
            else
              {:error, reason} -> {:halt, {:error, {:delete_failed, location.id, reason}}}
            end
          end
        else
          {:error, reason} -> {:halt, {:error, {:delete_failed, location.id, reason}}}
        end
      end
    end)
    |> case do
      {:ok, final_bytes, deleted} ->
        {:ok,
         %{
           deleted: Enum.reverse(deleted),
           forced_archived: forced_archived,
           archive_skipped: archive_skipped,
           deleted_orphans: deleted_orphans,
           bytes: final_bytes,
           max_bytes: max_bytes,
           over_limit_bytes: max(final_bytes - max_bytes, 0)
         }}

      error ->
        error
    end
  end

  defp total_bytes(locations, orphans) do
    existing_orphans =
      Enum.filter(orphans, fn orphan ->
        match?({:ok, %File.Stat{type: :directory}}, File.lstat(orphan.path))
      end)

    Enum.reduce_while(locations ++ existing_orphans, {:ok, %{}}, fn location, {:ok, inodes} ->
      screenshot_result =
        if Map.has_key?(location, :name),
          do: regular_files(location.screenshots_dir, true),
          else: screenshot_files(location.screenshots_dir)

      with {:ok, files} <- screenshot_result,
           {:ok, thumbnails} <- thumbnail_files(location.thumbnails_dir),
           {:ok, inodes} <- add_file_sizes(files ++ thumbnails, inodes) do
        {:cont, {:ok, inodes}}
      else
        {:error, reason} ->
          {:halt, {:error, {:size_failed, Map.get(location, :id, location[:name]), reason}}}
      end
    end)
    |> case do
      {:ok, inodes} -> {:ok, inodes |> Map.values() |> Enum.sum()}
      error -> error
    end
  end

  defp add_file_sizes(files, inodes) do
    Enum.reduce_while(files, {:ok, inodes}, fn path, {:ok, inodes} ->
      case File.stat(path) do
        {:ok, stat} ->
          identity = {stat.major_device, stat.minor_device, stat.inode}
          {:cont, {:ok, Map.put_new(inodes, identity, stat.size)}}

        {:error, reason} ->
          {:halt, {:error, {:stat_failed, path, reason}}}
      end
    end)
  end

  defp delete_files(files) do
    Enum.reduce_while(files, :ok, fn path, :ok ->
      case File.rm(path) do
        :ok -> {:cont, :ok}
        {:error, reason} -> {:halt, {:error, {:remove_failed, path, reason}}}
      end
    end)
  end

  defp value(map, key), do: Map.get(map, key) || Map.get(map, Atom.to_string(key))
end
