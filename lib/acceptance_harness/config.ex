defmodule AcceptanceHarness.Config do
  @moduledoc """
  Configuration accessors for the acceptance harness.
  """

  require Logger

  @default_commit_sha_env ["ACCEPTANCE_GIT_SHA", "CI_COMMIT_SHA"]
  def app_name do
    config(:app_name, "Acceptance")
  end

  def otp_app do
    config(:otp_app, :acceptance_harness)
  end

  def site_title do
    config(:site_title, "#{app_name()} ATDD Evidence")
  end

  def app_version do
    otp_app()
    |> Application.spec(:vsn)
    |> to_string()
  end

  def commit_sha_env do
    config(:commit_sha_env, @default_commit_sha_env)
  end

  def scenario_title_aliases do
    config(:scenario_title_aliases, %{})
  end

  def evidence_dir do
    config(:evidence_dir, "tmp/atdd")
  end

  def screenshot_dir do
    config(:screenshot_dir, Path.join(evidence_dir(), "screenshots"))
  end

  def trace_dir do
    config(:trace_dir, Path.join(evidence_dir(), "traces"))
  end

  def repo do
    config(:repo, nil)
  end

  def admin_acceptance_path do
    config(:admin_acceptance_path, nil)
  end

  @doc """
  Host-configurable maintenance action buttons rendered on the run index page
  (e.g. "Remove test data", "Relaunch ATDD").

  Each entry is a map or keyword list with:

    * `:id` (string, required, unique) — identifies the button (also used to
      build its DOM id).
    * `:label` (string, required) — the button text.
    * `:confirm` (string, optional) — a browser `confirm()` prompt shown
      before the action runs.
    * `:description` (string, optional) — a short muted line shown under the
      label.
    * `:run` (`{module, function, args}`, required) — the MFA invoked when
      the button is clicked. It should return `{:ok, message}` on success
      (shown as an info message) or `{:error, message}` on failure (shown as
      an error); any other return value shows a generic "Action finished."
      message, and a raised exception shows "Action failed: <message>".

  Long-running work is the host's responsibility: the MFA is called
  synchronously from the LiveView process, so hosts whose action needs more
  than a moment of work should spawn it themselves (e.g. with `Task.start/1`
  or a supervised job) and return `{:ok, "Started..."}` immediately rather
  than blocking the request.

  Malformed entries (missing required keys, wrong types, or a duplicate
  `:id`) are dropped and logged as a warning rather than raising.
  """
  def admin_actions do
    :admin_actions
    |> config([])
    |> List.wrap()
    |> Enum.reduce({[], MapSet.new()}, fn entry, {actions, seen_ids} ->
      case normalize_admin_action(entry) do
        {:ok, %{id: id} = action} ->
          if MapSet.member?(seen_ids, id) do
            Logger.warning(
              "acceptance_harness: dropping admin_action with duplicate id #{inspect(id)}"
            )

            {actions, seen_ids}
          else
            {[action | actions], MapSet.put(seen_ids, id)}
          end

        :error ->
          Logger.warning("acceptance_harness: dropping malformed admin_action: #{inspect(entry)}")
          {actions, seen_ids}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp normalize_admin_action(entry) when is_map(entry) or is_list(entry) do
    with {:ok, id} <- fetch_admin_action_string(entry, :id),
         {:ok, label} <- fetch_admin_action_string(entry, :label),
         {:ok, run} <- fetch_admin_action_mfa(entry) do
      {:ok,
       %{
         id: id,
         label: label,
         confirm: fetch_admin_action_optional_string(entry, :confirm),
         description: fetch_admin_action_optional_string(entry, :description),
         run: run
       }}
    else
      _ -> :error
    end
  end

  defp normalize_admin_action(_entry), do: :error

  defp fetch_admin_action_string(entry, key) do
    case admin_action_get(entry, key) do
      value when is_binary(value) and value != "" -> {:ok, value}
      _ -> :error
    end
  end

  defp fetch_admin_action_optional_string(entry, key) do
    case admin_action_get(entry, key) do
      value when is_binary(value) and value != "" -> value
      _ -> nil
    end
  end

  defp fetch_admin_action_mfa(entry) do
    case admin_action_get(entry, :run) do
      {module, function, args} when is_atom(module) and is_atom(function) and is_list(args) ->
        {:ok, {module, function, args}}

      _ ->
        :error
    end
  end

  defp admin_action_get(entry, key) when is_list(entry), do: Keyword.get(entry, key)

  defp admin_action_get(entry, key) when is_map(entry) do
    case Map.fetch(entry, key) do
      {:ok, value} -> value
      :error -> Map.get(entry, to_string(key))
    end
  end

  defp admin_action_get(_entry, _key), do: nil

  def admin_versions_path do
    config(:admin_versions_path, nil)
  end

  def base_url(opts \\ []) do
    default_port = Keyword.get(opts, :default_port, 4110)
    System.get_env("ATDD_BASE_URL", "http://localhost:#{default_port}")
  end

  def playwright(opts \\ []) do
    [
      browser_pool: Keyword.get(opts, :browser_pool, :chromium_pool),
      browser_pools:
        Keyword.get(opts, :browser_pools, [[id: :chromium_pool, browser: :chromium, size: 1]]),
      browser_launch_timeout: Keyword.get(opts, :browser_launch_timeout, 10_000),
      screenshot_dir: Keyword.get(opts, :screenshot_dir, screenshot_dir()),
      trace_dir: Keyword.get(opts, :trace_dir, trace_dir()),
      screenshot: Keyword.get(opts, :screenshot, full_page: false),
      trace: System.get_env("PW_TRACE", "false") in ~w(t true),
      timeout: Keyword.get(opts, :timeout, 5_000)
    ]
  end

  defp config(key, default) do
    :acceptance_harness
    |> Application.get_env(:harness, [])
    |> Keyword.get(key, default)
  end
end
