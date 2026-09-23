defmodule AcceptanceHarness.FakeTerminalTransport do
  @behaviour AcceptanceHarness.Terminal.Transport

  use GenServer

  @impl true
  def start(options) do
    caller = self()
    GenServer.start(__MODULE__, {caller, options})
  end

  @impl true
  def input(session, bytes), do: GenServer.call(session, {:input, IO.iodata_to_binary(bytes)})

  @impl true
  def resize(session, rows, columns), do: GenServer.call(session, {:resize, rows, columns})

  @impl true
  def snapshot(session), do: GenServer.call(session, :snapshot)

  @impl true
  def stop(session, reason), do: GenServer.call(session, {:stop, reason})

  def emit(session, event), do: GenServer.call(session, {:emit, event})

  @impl true
  def init({caller, options}) do
    target = Keyword.get(options, :event_target, caller)
    send(target, {:terminal_transport, self(), {:started, 1234}})

    {:ok,
     %{
       target: target,
       observer: Keyword.get(options, :observer, caller),
       snapshot: Keyword.get(options, :snapshot, %{rows: 24, columns: 80, text: ""})
     }}
  end

  @impl true
  def handle_call({:input, bytes}, _from, state) do
    send(state.observer, {:fake_terminal_input, self(), bytes})
    {:reply, :ok, state}
  end

  def handle_call({:resize, rows, columns}, _from, state) do
    send(state.observer, {:fake_terminal_resize, self(), rows, columns})
    {:reply, :ok, state}
  end

  def handle_call({:emit, event}, _from, state) do
    send(state.target, {:terminal_transport, self(), event})
    {:reply, :ok, state}
  end

  def handle_call(:snapshot, _from, state), do: {:reply, {:ok, state.snapshot}, state}

  def handle_call({:stop, reason}, _from, state) do
    send(state.observer, {:fake_terminal_stop, self(), reason})
    {:stop, :normal, :ok, state}
  end
end
