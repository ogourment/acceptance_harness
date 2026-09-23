defmodule AcceptanceHarness.Deployment do
  @moduledoc """
  Reads current deployment identity and searchable deployment history.

  Consumers may use the built-in environment/JSONL providers or configure
  zero-arity functions (or MFA tuples) with `:current_provider` and
  `:history_provider`.
  """

  @default_page_size 10
  @max_page_size 100

  @spec current(keyword()) :: map()
  def current(opts \\ []) do
    opts = merged_config(opts)

    opts
    |> Keyword.get(:current_provider)
    |> provider_value(fn -> current_from_environment(opts) end)
    |> normalize_row()
    |> Map.put("current", true)
  end

  @spec history(keyword()) :: [map()]
  def history(opts \\ []) do
    opts = merged_config(opts)

    opts
    |> Keyword.get(:history_provider)
    |> provider_value(fn -> history_from_jsonl(Keyword.get(opts, :history_path)) end)
    |> List.wrap()
    |> Enum.filter(&is_map/1)
    |> Enum.map(&normalize_row/1)
  end

  @spec rows(keyword()) :: [map()]
  def rows(opts \\ []) do
    if Keyword.get(merged_config(opts), :include_current, true) do
      [current(opts) | history(opts)]
    else
      history(opts)
    end
  end

  @spec list(map(), keyword()) :: map()
  def list(params \\ %{}, opts \\ []) when is_map(params) do
    rows(opts)
    |> paginate(params, opts)
  end

  @spec paginate([map()], map(), keyword()) :: map()
  def paginate(rows, params, opts \\ []) when is_list(rows) and is_map(params) do
    opts = merged_config(opts)
    query = params |> Map.get("q", "") |> to_string() |> String.trim()

    page_size =
      positive_integer(
        Map.get(params, "page_size"),
        Keyword.get(opts, :page_size, @default_page_size)
      )

    page_size = min(page_size, @max_page_size)

    filtered_rows = Enum.filter(rows, &matches_query?(&1, query))
    total = length(filtered_rows)
    total_pages = max(ceil_div(total, page_size), 1)
    page = params |> Map.get("page") |> positive_integer(1) |> min(total_pages)

    %{
      rows: Enum.slice(filtered_rows, (page - 1) * page_size, page_size),
      query: query,
      page: page,
      page_size: page_size,
      total: total,
      total_pages: total_pages
    }
  end

  defp current_from_environment(opts) do
    otp_app = Keyword.get(opts, :otp_app, :acceptance_harness)
    prefix = Keyword.get(opts, :env_prefix, default_prefix(otp_app))

    %{
      "app" => metadata(prefix, "APP_NAME", Atom.to_string(otp_app)),
      "app_version" => metadata(prefix, "APP_VERSION", app_version(otp_app)),
      "release_id" => metadata(prefix, "RELEASE_ID", "unknown"),
      "environment" => metadata(prefix, "DISPLAY_ENV", "unknown"),
      "slot" => metadata(prefix, "COLOR", "unknown"),
      "pipeline_id" => metadata(prefix, "CI_PIPELINE_ID", "unknown"),
      "git_sha" => metadata(prefix, "GIT_SHA", "unknown"),
      "git_ref" => metadata(prefix, "GIT_REF", "unknown"),
      "git_messages" => git_messages(metadata(prefix, "GIT_MESSAGES", "")),
      "deployed_at" => metadata(prefix, "DEPLOYED_AT", ""),
      "node" => to_string(Node.self())
    }
  end

  defp history_from_jsonl(nil), do: []
  defp history_from_jsonl(""), do: []

  defp history_from_jsonl(path) when is_binary(path) do
    if File.regular?(path) do
      path
      |> File.stream!()
      |> Stream.map(&String.trim/1)
      |> Stream.reject(&(&1 == ""))
      |> Stream.map(&Jason.decode/1)
      |> Stream.filter(&match?({:ok, row} when is_map(row), &1))
      |> Enum.map(fn {:ok, row} -> row end)
      |> Enum.reverse()
    else
      []
    end
  rescue
    File.Error -> []
  end

  defp matches_query?(_row, ""), do: true

  defp matches_query?(row, query) do
    haystack =
      row
      |> searchable_values()
      |> Enum.join(" ")
      |> String.downcase()

    query
    |> String.downcase()
    |> String.split(~r/\s+/, trim: true)
    |> Enum.all?(&String.contains?(haystack, &1))
  end

  defp searchable_values(value) when is_map(value),
    do: Enum.flat_map(value, fn {_key, item} -> searchable_values(item) end)

  defp searchable_values(value) when is_list(value),
    do: Enum.flat_map(value, &searchable_values/1)

  defp searchable_values(nil), do: []
  defp searchable_values(value), do: [to_string(value)]

  defp normalize_row(row) do
    row = Map.new(row, fn {key, value} -> {to_string(key), value} end)

    messages =
      case git_messages(Map.get(row, "git_messages")) do
        [] -> git_messages(Map.get(row, "git_subject"))
        messages -> messages
      end

    row
    |> put_alias("app_version", "version")
    |> put_alias("environment", "env")
    |> put_alias("slot", "color")
    |> Map.put("git_messages", messages)
  end

  defp put_alias(row, target, source) do
    case Map.get(row, target) do
      value when value not in [nil, ""] -> row
      _ -> Map.put(row, target, Map.get(row, source))
    end
  end

  defp git_messages(messages) when is_list(messages) do
    messages
    |> Enum.map(&to_string/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
  end

  defp git_messages(messages) when is_binary(messages) do
    messages
    |> String.split(["\r\n", "\n", "\\n"], trim: true)
    |> git_messages()
  end

  defp git_messages(_messages), do: []

  defp provider_value(nil, fallback), do: fallback.()
  defp provider_value(provider, _fallback) when is_function(provider, 0), do: provider.()
  defp provider_value({module, function, args}, _fallback), do: apply(module, function, args)

  defp merged_config(opts) do
    health_config = Application.get_env(:acceptance_harness, :health, [])

    :acceptance_harness
    |> Application.get_env(:deployment, [])
    |> then(&Keyword.merge(health_config, &1))
    |> Keyword.merge(opts)
  end

  defp app_version(otp_app) do
    case Application.spec(otp_app, :vsn) do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  defp default_prefix(otp_app), do: otp_app |> Atom.to_string() |> String.upcase()

  defp metadata(prefix, suffix, default) do
    case System.get_env("#{prefix}_#{suffix}") do
      value when is_binary(value) and value != "" -> value
      _ -> default
    end
  end

  defp positive_integer(value, _default) when is_integer(value) and value > 0, do: value

  defp positive_integer(value, default) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _ -> default
    end
  end

  defp positive_integer(_value, default), do: default
  defp ceil_div(0, _divisor), do: 0
  defp ceil_div(dividend, divisor), do: div(dividend + divisor - 1, divisor)
end
