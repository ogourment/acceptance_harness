defmodule AcceptanceHarness.Terminal.PortTransport do
  @moduledoc """
  Supervised Port adapter for the harness-owned PTY helper.

  Events are delivered to `:event_target` (the caller by default):

      {:terminal_transport, session, {:started, os_pid}}
      {:terminal_transport, session, {:output, raw_bytes}}
      {:terminal_transport, session, {:exited, exit_status}}
      {:terminal_transport, session, {:error, message}}
  """

  use GenServer

  @behaviour AcceptanceHarness.Terminal.Transport

  @start 0x01
  @input 0x02
  @resize 0x03
  @stop 0x04
  @snapshot 0x05
  @started 0x81
  @output 0x82
  @exited 0x83
  @resized 0x84
  @snapshot_ready 0x85
  @error 0xFF
  @default_stop_timeout 2_000

  @impl true
  def start(options) do
    timeout = Keyword.get(options, :start_timeout, 5_000)

    with {:ok, session} <-
           DynamicSupervisor.start_child(
             AcceptanceHarness.Terminal.Supervisor,
             {__MODULE__, {self(), options}}
           ),
         :ok <- GenServer.call(session, :start, timeout) do
      {:ok, session}
    end
  catch
    :exit, {:timeout, _} -> {:error, :start_timeout}
    :exit, reason -> {:error, reason}
  end

  def start_link(init), do: GenServer.start_link(__MODULE__, init)

  def child_spec(init) do
    %{
      id: {__MODULE__, make_ref()},
      start: {__MODULE__, :start_link, [init]},
      restart: :temporary,
      type: :worker
    }
  end

  @impl true
  def input(session, data), do: GenServer.call(session, {:input, IO.iodata_to_binary(data)})

  @impl true
  def resize(session, rows, cols)
      when is_integer(rows) and rows > 0 and rows <= 65_535 and is_integer(cols) and cols > 0 and
             cols <= 65_535 do
    GenServer.call(session, {:resize, rows, cols})
  end

  @impl true
  def stop(session, reason) do
    GenServer.call(session, {:stop, reason}, @default_stop_timeout)
  catch
    :exit, {:timeout, _} -> force_close(session, :stop_timeout)
    :exit, {:noproc, _} -> :ok
  end

  @impl true
  def snapshot(session), do: GenServer.call(session, :snapshot)

  @impl true
  def init({caller, options}) do
    owner = Keyword.get(options, :owner, caller)
    target = Keyword.get(options, :event_target, caller)

    case open_helper(Keyword.get(options, :helper_path)) do
      {:ok, port} ->
        {:ok,
         %{
           port: port,
           owner_ref: Process.monitor(owner),
           target: target,
           start_frame: encode_start(options),
           start_from: nil,
           resize_from: nil,
           snapshot_from: nil,
           stop_from: nil
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:start, from, state) do
    true = Port.command(state.port, state.start_frame)
    {:noreply, %{state | start_from: from}}
  end

  def handle_call({:input, bytes}, _from, state) do
    {:reply, port_command(state, <<@input, bytes::binary>>), state}
  end

  def handle_call({:resize, _rows, _cols}, _from, %{resize_from: from} = state)
      when not is_nil(from) do
    {:reply, {:error, :resize_in_progress}, state}
  end

  def handle_call({:resize, rows, cols}, from, state) do
    case port_command(state, <<@resize, rows::16, cols::16>>) do
      :ok -> {:noreply, %{state | resize_from: from}}
      error -> {:reply, error, state}
    end
  end

  def handle_call({:stop, _reason}, from, state) do
    _ = port_command(state, <<@stop>>)
    {:noreply, %{state | stop_from: from}}
  end

  def handle_call(:snapshot, _from, %{snapshot_from: from} = state) when not is_nil(from),
    do: {:reply, {:error, :snapshot_in_progress}, state}

  def handle_call(:snapshot, from, state) do
    case port_command(state, <<@snapshot>>) do
      :ok -> {:noreply, %{state | snapshot_from: from}}
      error -> {:reply, error, state}
    end
  end

  @impl true
  def handle_info({port, {:data, frame}}, %{port: port} = state) do
    handle_event(frame, state)
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    state = reply_start(state, {:error, {:helper_exit, status}})
    state = reply_stop(state, if(status == 0, do: :ok, else: {:error, {:helper_exit, status}}))
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    _ = port_command(state, <<@stop>>)
    Process.send_after(self(), :force_owner_cleanup, @default_stop_timeout)
    {:noreply, state}
  end

  def handle_info(:force_owner_cleanup, state), do: {:stop, :normal, state}

  @impl true
  def terminate(_reason, state) do
    if is_port(state.port) and Port.info(state.port) do
      Port.close(state.port)
    end

    :ok
  catch
    :error, :badarg -> :ok
  end

  defp handle_event(<<@started, os_pid::32>>, state) do
    send_event(state, {:started, os_pid})
    {:noreply, reply_start(state, :ok)}
  end

  defp handle_event(<<@output, bytes::binary>>, state) do
    send_event(state, {:output, bytes})
    {:noreply, state}
  end

  defp handle_event(<<@exited, status::signed-32>>, state) do
    send_event(state, {:exited, status})
    {:noreply, reply_stop(state, :ok)}
  end

  defp handle_event(<<@resized>>, state) do
    if state.resize_from, do: GenServer.reply(state.resize_from, :ok)
    {:noreply, %{state | resize_from: nil}}
  end

  defp handle_event(<<@snapshot_ready, rows::16, columns::16, text::binary>>, state) do
    if state.snapshot_from do
      GenServer.reply(state.snapshot_from, {:ok, %{rows: rows, columns: columns, text: text}})
    end

    {:noreply, %{state | snapshot_from: nil}}
  end

  defp handle_event(<<@error, message::binary>>, state) do
    error = {:helper_error, message}
    send_event(state, {:error, message})
    {:noreply, reply_start(state, {:error, error})}
  end

  defp handle_event(frame, state) do
    send_event(state, {:error, "unknown helper event: #{inspect(frame)}"})
    {:noreply, state}
  end

  defp send_event(state, event), do: send(state.target, {:terminal_transport, self(), event})

  defp reply_start(%{start_from: nil} = state, _reply), do: state

  defp reply_start(state, reply) do
    GenServer.reply(state.start_from, reply)
    %{state | start_from: nil}
  end

  defp reply_stop(%{stop_from: nil} = state, _reply), do: state

  defp reply_stop(state, reply) do
    GenServer.reply(state.stop_from, reply)
    %{state | stop_from: nil}
  end

  defp port_command(state, frame) do
    if Port.command(state.port, frame), do: :ok, else: {:error, :closed}
  catch
    :error, :badarg -> {:error, :closed}
  end

  defp open_helper(configured_path) do
    path = configured_path || helper_path()

    if File.regular?(path) do
      {:ok,
       Port.open({:spawn_executable, path}, [
         :binary,
         {:packet, 4},
         :exit_status,
         :use_stdio
       ])}
    else
      {:error, {:helper_not_found, path}}
    end
  end

  defp helper_path do
    configured = Application.get_env(:acceptance_harness, :terminal_helper_path)

    configured ||
      Path.expand(
        "../../../native/pty_helper/target/release/acceptance-harness-pty-helper",
        __DIR__
      )
  end

  defp encode_start(options) do
    rows = Keyword.get(options, :rows, 24)
    cols = Keyword.get(options, :cols, 80)
    cwd = Keyword.get(options, :cwd, "")
    environment = options |> Keyword.get(:env, %{}) |> Enum.sort()
    argv = Keyword.fetch!(options, :command)

    <<
      @start,
      rows::16,
      cols::16,
      encode_string(cwd)::binary,
      length(environment)::16,
      encode_environment(environment)::binary,
      length(argv)::16,
      encode_strings(argv)::binary
    >>
  end

  defp encode_environment(environment) do
    Enum.map_join(environment, fn {name, value} -> encode_string(name) <> encode_string(value) end)
  end

  defp encode_strings(strings), do: Enum.map_join(strings, &encode_string/1)

  defp encode_string(value) do
    value = to_string(value)
    <<byte_size(value)::32, value::binary>>
  end

  defp force_close(session, reason) do
    if Process.alive?(session), do: GenServer.stop(session, reason)
    {:error, reason}
  end
end
