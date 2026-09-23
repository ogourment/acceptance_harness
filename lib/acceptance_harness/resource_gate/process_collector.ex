defmodule AcceptanceHarness.ResourceGate.ProcessCollector do
  @moduledoc """
  Portable RSS collector for a local GNOME process or iOS Simulator app.

  Physical Apple devices require an Instruments-backed adapter; their remote
  process identifiers must not be passed to this host-process collector.
  """

  @behaviour AcceptanceHarness.ResourceGate.Collector

  @enforce_keys [
    :pid,
    :platform,
    :baseline_bytes,
    :peak_bytes,
    :sample_count,
    :budget,
    :rss_reader,
    :handle_reader
  ]
  defstruct @enforce_keys ++ [:baseline_handle_count, :max_handle_growth, :settle_ms]

  @impl true
  def start(options) do
    with {:ok, pid} <- required_positive_integer(options, :pid),
         {:ok, platform} <- supported_platform(options),
         {:ok, budget} <- required_nonnegative_integer(options, :max_retained_growth_bytes),
         {:ok, rss_reader} <- rss_reader(options),
         handle_reader <- Keyword.get(options, :handle_reader, &handle_count/1),
         {:ok, rss} <- rss_reader.(pid) do
      {:ok,
       %__MODULE__{
         pid: pid,
         platform: platform,
         baseline_bytes: rss,
         peak_bytes: rss,
         sample_count: 1,
         budget: budget,
         rss_reader: rss_reader,
         handle_reader: handle_reader,
         baseline_handle_count: handle_reader.(pid),
         max_handle_growth: Keyword.get(options, :max_handle_growth),
         settle_ms: Keyword.get(options, :settle_ms, 0)
       }}
    else
      {:skip, _reason} = skipped -> skipped
      {:error, reason} -> {:error, reason}
    end
  end

  @impl true
  def sample(%__MODULE__{} = state) do
    case state.rss_reader.(state.pid) do
      {:ok, rss} ->
        {:ok,
         %{state | peak_bytes: max(state.peak_bytes, rss), sample_count: state.sample_count + 1}}

      {:error, _reason} = error ->
        error
    end
  end

  @impl true
  def finish(%__MODULE__{} = state) do
    if state.settle_ms > 0, do: Process.sleep(state.settle_ms)

    case state.rss_reader.(state.pid) do
      {:ok, settled} ->
        settled_handles = state.handle_reader.(state.pid)

        {:ok,
         %{
           collector_status: :collected,
           collector: "posix-process-rss.v1",
           platform: state.platform,
           process_id: state.pid,
           baseline_bytes: state.baseline_bytes,
           peak_bytes: max(state.peak_bytes, settled),
           settled_bytes: settled,
           sample_count: state.sample_count + 1,
           process_survived: true,
           max_retained_growth_bytes: state.budget,
           baseline_handle_count: state.baseline_handle_count,
           settled_handle_count: settled_handles,
           max_handle_growth: state.max_handle_growth,
           leak_check: :unavailable
         }}

      {:error, reason} ->
        {:ok,
         %{
           collector_status: :collected,
           collector: "posix-process-rss.v1",
           platform: state.platform,
           process_id: state.pid,
           baseline_bytes: state.baseline_bytes,
           peak_bytes: state.peak_bytes,
           settled_bytes: state.peak_bytes,
           sample_count: state.sample_count,
           process_survived: false,
           termination_reason: inspect(reason),
           max_retained_growth_bytes: state.budget,
           leak_check: :unavailable
         }}
    end
  end

  defp supported_platform(options) do
    case Keyword.fetch(options, :platform) do
      {:ok, platform} when platform in [:gnome, :ios_simulator, :macos] -> {:ok, platform}
      {:ok, :ios_physical} -> {:skip, "physical iOS requires an Instruments collector"}
      {:ok, platform} -> {:skip, "unsupported process collector platform: #{inspect(platform)}"}
      :error -> {:error, {:missing_option, :platform}}
    end
  end

  defp required_positive_integer(options, key) do
    case Keyword.fetch(options, key) do
      {:ok, value} when is_integer(value) and value > 0 -> {:ok, value}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  defp required_nonnegative_integer(options, key) do
    case Keyword.fetch(options, key) do
      {:ok, value} when is_integer(value) and value >= 0 -> {:ok, value}
      _ -> {:error, {:invalid_option, key}}
    end
  end

  defp rss_reader(options) do
    case Keyword.get(options, :rss_reader) do
      reader when is_function(reader, 1) -> {:ok, reader}
      nil -> default_rss_reader()
      _invalid -> {:error, {:invalid_option, :rss_reader}}
    end
  end

  defp default_rss_reader do
    case System.find_executable("ps") do
      nil -> {:skip, "ps is unavailable on this runner"}
      executable -> {:ok, fn pid -> rss_bytes(executable, pid) end}
    end
  end

  defp rss_bytes(executable, pid) do
    case System.cmd(executable, ["-o", "rss=", "-p", Integer.to_string(pid)],
           stderr_to_stdout: true
         ) do
      {output, 0} ->
        case Integer.parse(String.trim(output)) do
          {kilobytes, ""} when kilobytes >= 0 -> {:ok, kilobytes * 1_024}
          _ -> {:error, :invalid_rss}
        end

      {_output, _status} ->
        {:error, :process_unavailable}
    end
  end

  defp handle_count(pid) do
    proc_path = "/proc/#{pid}/fd"

    cond do
      File.dir?(proc_path) ->
        case File.ls(proc_path) do
          {:ok, entries} -> length(entries)
          {:error, _reason} -> nil
        end

      System.find_executable("lsof") ->
        case System.cmd("lsof", ["-n", "-P", "-p", Integer.to_string(pid)],
               stderr_to_stdout: true
             ) do
          {output, 0} -> max(length(String.split(output, "\n", trim: true)) - 1, 0)
          {_output, _status} -> nil
        end

      true ->
        nil
    end
  end
end
