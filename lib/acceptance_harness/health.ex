defmodule AcceptanceHarness.Health do
  @moduledoc """
  Builds the shared, machine-readable health payload for Phoenix consumers.

  Configure the consumer's OTP application and deployment environment prefix:

      config :acceptance_harness, :health,
        otp_app: :my_app,
        env_prefix: "MY_APP"

  The deployment harness writes release and pipeline metadata using that prefix.
  """

  @type config :: keyword()
  @identity_fields [:release_id, :pipeline_id]

  @spec payload(config()) :: map()
  def payload(config \\ config()) do
    otp_app = Keyword.get(config, :otp_app, :acceptance_harness)
    env_prefix = Keyword.get(config, :env_prefix, default_prefix(otp_app))
    age_seconds = age_seconds()

    %{
      status: "ok",
      version: app_version(otp_app),
      release_id: metadata(env_prefix, "RELEASE_ID"),
      env: metadata(env_prefix, "DISPLAY_ENV"),
      color: metadata(env_prefix, "COLOR"),
      age_seconds: age_seconds,
      age: format_age(age_seconds),
      pipeline_id: metadata(env_prefix, "CI_PIPELINE_ID")
    }
  end

  @doc """
  Validates that a deployed health payload identifies its immutable release and
  CI pipeline. Local and test callers should opt in only when deployment
  identity is part of the environment contract.
  """
  @spec validate_deployed_identity(map()) :: :ok | {:error, [atom()]}
  def validate_deployed_identity(payload) when is_map(payload) do
    missing = Enum.filter(@identity_fields, &missing_identity?(identity_value(payload, &1)))

    if missing == [], do: :ok, else: {:error, missing}
  end

  @doc "Raises when deployed release or pipeline identity is missing."
  @spec validate_deployed_identity!(map()) :: :ok
  def validate_deployed_identity!(payload) when is_map(payload) do
    case validate_deployed_identity(payload) do
      :ok ->
        :ok

      {:error, missing} ->
        fields = Enum.map_join(missing, ", ", &Atom.to_string/1)
        raise ArgumentError, "deployed health identity is missing: #{fields}"
    end
  end

  @doc false
  @spec age_seconds(integer(), integer()) :: non_neg_integer()
  def age_seconds(now \\ System.monotonic_time(), started_at \\ :erlang.system_info(:start_time)) do
    now
    |> Kernel.-(started_at)
    |> System.convert_time_unit(:native, :second)
    |> max(0)
  end

  @doc false
  @spec format_age(non_neg_integer()) :: String.t()
  def format_age(seconds) when is_integer(seconds) and seconds >= 0 do
    days = div(seconds, 86_400)
    hours = seconds |> rem(86_400) |> div(3_600)
    minutes = seconds |> rem(3_600) |> div(60)
    remaining_seconds = rem(seconds, 60)

    [
      if(days > 0, do: "#{days}d"),
      if(days > 0 or hours > 0, do: String.pad_leading("#{hours}h", 3, "0")),
      if(days > 0 or hours > 0 or minutes > 0, do: String.pad_leading("#{minutes}m", 3, "0")),
      String.pad_leading("#{remaining_seconds}s", 3, "0")
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp config, do: Application.get_env(:acceptance_harness, :health, [])

  defp app_version(otp_app) do
    otp_app
    |> Application.spec(:vsn)
    |> case do
      nil -> "unknown"
      version -> to_string(version)
    end
  end

  defp default_prefix(otp_app) do
    otp_app
    |> Atom.to_string()
    |> String.upcase()
  end

  defp metadata(prefix, name) do
    System.get_env("#{prefix}_#{name}") || "unknown"
  end

  defp identity_value(payload, field) do
    Map.get(payload, field) || Map.get(payload, Atom.to_string(field))
  end

  defp missing_identity?(value) when is_binary(value), do: String.trim(value) in ["", "unknown"]
  defp missing_identity?(_value), do: true
end
