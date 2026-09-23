defmodule AcceptanceHarness.JobTiming do
  @moduledoc """
  Captures CI job timing once per evidence run. Job creation-to-start includes
  dependency waits; GitLab's runner queue duration is retained separately.
  Only timing and job identity fields are retained, never API response bodies.
  """

  def capture(env \\ System.get_env(), fetch \\ &fetch_job/1) do
    cond do
      present?(env["CI_JOB_CREATED_AT"]) and present?(env["CI_JOB_STARTED_AT"]) ->
        from_job(
          %{
            "id" => env["CI_JOB_ID"],
            "created_at" => env["CI_JOB_CREATED_AT"],
            "started_at" => env["CI_JOB_STARTED_AT"]
          },
          "environment"
        )

      present?(env["ATDD_JOB_WAIT_SECONDS"]) ->
        case milliseconds(env["ATDD_JOB_WAIT_SECONDS"]) do
          nil ->
            unavailable("invalid", "Invalid ATDD_JOB_WAIT_SECONDS")

          ms ->
            %{job_wait_ms: ms, job_timing: %{status: "available", source: "duration_environment"}}
        end

      present?(env["CI_JOB_ID"]) ->
        case fetch.(env) do
          {:ok, %{"id" => id} = job} ->
            if to_string(id) == env["CI_JOB_ID"],
              do: from_job(job, "gitlab_job_api"),
              else: unavailable("invalid", "Job metadata identity does not match this attempt")

          _ ->
            unavailable("unavailable", "Job timestamps unavailable; check CI job API access")
        end

      true ->
        unavailable("not_applicable", "Local run; no CI job")
    end
  end

  def from_job(job, source \\ "gitlab_job_api") do
    identity = Map.take(job, ["id", "created_at", "started_at"])

    with {:ok, created, _} <- parse_datetime(job["created_at"]),
         {:ok, started, _} <- parse_datetime(job["started_at"]),
         ms when ms >= 0 <- DateTime.diff(started, created, :millisecond) do
      %{
        job_wait_ms: ms,
        runner_queue_ms: milliseconds(job["queued_duration"]),
        job_timing: Map.merge(identity, %{status: "available", source: source})
      }
    else
      _ ->
        unavailable("invalid", "Missing, malformed or reversed job timestamps")
        |> Map.update!(:job_timing, &Map.merge(&1, identity))
    end
  end

  defp unavailable(status, reason),
    do: %{job_wait_ms: nil, job_timing: %{status: status, reason: reason}}

  defp parse_datetime(value) when is_binary(value), do: DateTime.from_iso8601(value)
  defp parse_datetime(_), do: :error
  defp present?(value), do: is_binary(value) and value != ""

  defp milliseconds(value) when is_number(value) and value >= 0, do: round(value * 1000)

  defp milliseconds(value) when is_binary(value) do
    case Float.parse(value) do
      {seconds, ""} when seconds >= 0 -> round(seconds * 1000)
      _ -> nil
    end
  end

  defp milliseconds(_), do: nil

  defp fetch_job(env) do
    # The job-token endpoint identifies this attempt without a personal API key.
    # Never follow redirects with the token and never log the response or errors.
    with token when is_binary(token) and token != "" <- env["CI_JOB_TOKEN"],
         root when is_binary(root) <- env["CI_API_V4_URL"],
         %URI{scheme: "https", host: host, userinfo: nil} when is_binary(host) <- URI.parse(root),
         {:ok, _} <- Application.ensure_all_started(:inets),
         {:ok, _} <- Application.ensure_all_started(:ssl),
         {:ok, {{_, 200, _}, _, body}} <-
           :httpc.request(
             :get,
             {String.to_charlist(String.trim_trailing(root, "/") <> "/job"),
              [{~c"job-token", String.to_charlist(token)}]},
             [
               timeout: 3000,
               connect_timeout: 2000,
               autoredirect: false,
               ssl: [
                 verify: :verify_peer,
                 cacerts: :public_key.cacerts_get(),
                 customize_hostname_check: [
                   match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
                 ]
               ]
             ],
             body_format: :binary
           ),
         {:ok, job} when is_map(job) <- Jason.decode(body) do
      {:ok, job}
    else
      _ -> {:error, :unavailable}
    end
  rescue
    _ -> {:error, :unavailable}
  end
end
