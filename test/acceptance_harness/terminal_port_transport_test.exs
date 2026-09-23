defmodule AcceptanceHarness.Terminal.PortTransportTest do
  use ExUnit.Case, async: false

  alias AcceptanceHarness.Terminal.PortTransport

  @helper Path.expand(
            "../../native/pty_helper/target/release/acceptance-harness-pty-helper",
            __DIR__
          )

  setup_all do
    {output, status} =
      System.cmd(
        "cargo",
        ["build", "--release", "--locked", "--manifest-path", "native/pty_helper/Cargo.toml"],
        cd: Path.expand("../..", __DIR__),
        stderr_to_stdout: true
      )

    if status != 0, do: raise("PTY helper build failed:\n#{output}")
    :ok
  end

  test "reports initial and runtime size while preserving raw ANSI and fragmented UTF-8" do
    script = ~S"""
    printf 'initial:'; stty size
    read line
    printf 'resized:'; stty size
    printf '\033[31m'
    printf 'caf'
    sleep 0.02
    printf '\303'
    sleep 0.02
    printf '\251 \316\224'
    printf '\033[0m\n'
    exit 7
    """

    assert {:ok, session} =
             PortTransport.start(
               command: ["/bin/sh", "-c", script],
               rows: 33,
               cols: 91,
               helper_path: @helper
             )

    initial = collect_until(session, &String.contains?(&1, "initial:33 91"))
    assert initial =~ "initial:33 91\r\n"

    assert :ok = PortTransport.resize(session, 21, 72)
    assert :ok = PortTransport.input(session, "go\n")

    {raw, status} = collect_until_exit(session)
    assert status == 7
    assert raw =~ "resized:21 72\r\n"
    assert raw =~ "\e[31mcafé Δ\e[0m\r\n"
    assert String.valid?(initial <> raw)
  end

  test "returns a prompt tagged error for an executable that does not exist" do
    started_at = System.monotonic_time(:millisecond)

    assert {:error, {:helper_error, message}} =
             PortTransport.start(
               command: ["/definitely/not/an/acceptance-harness-command"],
               helper_path: @helper,
               start_timeout: 2_000
             )

    assert message =~ "spawn"
    assert System.monotonic_time(:millisecond) - started_at < 2_000
  end

  test "explicit stop kills and reaps the child and closes the session" do
    assert {:ok, session} =
             PortTransport.start(
               command: ["/bin/sh", "-c", "echo parent:$$; sleep 30 & echo child:$!; wait"],
               helper_path: @helper
             )

    output = collect_until(session, &String.contains?(&1, "child:"))
    [_, parent_pid] = Regex.run(~r/parent:(\d+)/, output)
    [_, child_pid] = Regex.run(~r/child:(\d+)/, output)
    session_ref = Process.monitor(session)

    assert :ok = PortTransport.stop(session, :scenario_complete)
    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}, 2_000
    refute os_process_alive?(String.to_integer(parent_pid))
    refute os_process_alive?(String.to_integer(child_pid))
  end

  test "owner exit tears down its child and supervised session" do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, session} =
          PortTransport.start(
            command: ["/bin/sh", "-c", "echo parent:$$; sleep 30 & echo child:$!; wait"],
            helper_path: @helper,
            event_target: parent
          )

        send(parent, {:owned_session, session})
        Process.sleep(:infinity)
      end)

    assert_receive {:owned_session, session}, 2_000
    output = collect_until(session, &String.contains?(&1, "child:"))
    [_, parent_pid] = Regex.run(~r/parent:(\d+)/, output)
    [_, child_pid] = Regex.run(~r/child:(\d+)/, output)
    session_ref = Process.monitor(session)

    Process.exit(owner, :kill)

    assert_receive {:DOWN, ^session_ref, :process, ^session, :normal}, 3_000
    refute os_process_alive?(String.to_integer(parent_pid))
    refute os_process_alive?(String.to_integer(child_pid))
  end

  defp collect_until(session, predicate, buffer \\ "") do
    receive do
      {:terminal_transport, ^session, {:output, bytes}} ->
        buffer = buffer <> bytes
        if predicate.(buffer), do: buffer, else: collect_until(session, predicate, buffer)

      {:terminal_transport, ^session, {:error, message}} ->
        flunk("terminal helper failed: #{message}")
    after
      2_000 -> flunk("timed out waiting for terminal output; received #{inspect(buffer)}")
    end
  end

  defp collect_until_exit(session, buffer \\ "") do
    receive do
      {:terminal_transport, ^session, {:output, bytes}} ->
        collect_until_exit(session, buffer <> bytes)

      {:terminal_transport, ^session, {:exited, status}} ->
        {buffer, status}

      {:terminal_transport, ^session, {:error, message}} ->
        flunk("terminal helper failed: #{message}")
    after
      2_000 -> flunk("timed out waiting for terminal exit; received #{inspect(buffer)}")
    end
  end

  defp os_process_alive?(pid) do
    case System.cmd(
           "/bin/sh",
           [
             "-c",
             "kill -0 \"$1\" 2>/dev/null",
             "acceptance-harness-process-probe",
             Integer.to_string(pid)
           ],
           stderr_to_stdout: true
         ) do
      {_, 0} -> true
      _ -> false
    end
  end
end
