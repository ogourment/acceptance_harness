defmodule AcceptanceHarness.HealthTest do
  use ExUnit.Case, async: false

  alias AcceptanceHarness.Health

  @env_names ~w(
    TEST_APP_RELEASE_ID
    TEST_APP_DISPLAY_ENV
    TEST_APP_COLOR
    TEST_APP_CI_PIPELINE_ID
  )

  setup do
    previous = Map.new(@env_names, &{&1, System.get_env(&1)})

    on_exit(fn ->
      Enum.each(previous, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)
    end)
  end

  test "returns deployment and pipeline metadata" do
    values = %{
      "TEST_APP_RELEASE_ID" => "v1.2.3-abc-42",
      "TEST_APP_DISPLAY_ENV" => "staging",
      "TEST_APP_COLOR" => "blue",
      "TEST_APP_CI_PIPELINE_ID" => "1398602"
    }

    Enum.each(values, fn {name, value} -> System.put_env(name, value) end)

    payload = Health.payload(otp_app: :acceptance_harness, env_prefix: "TEST_APP")

    assert payload.status == "ok"
    assert payload.release_id == "v1.2.3-abc-42"
    assert payload.env == "staging"
    assert payload.color == "blue"
    assert payload.age_seconds >= 0

    assert payload.pipeline_id == "1398602"
  end

  test "formats a compact human-readable process age" do
    assert Health.format_age(0) == "00s"
    assert Health.format_age(62) == "01m 02s"
    assert Health.format_age(3_723) == "01h 02m 03s"
    assert Health.format_age(90_061) == "1d 01h 01m 01s"
  end

  test "validates deployed release and pipeline identity" do
    payload = %{release_id: "v1.2.3-abc-42", pipeline_id: "42"}

    assert :ok = Health.validate_deployed_identity(payload)
    assert :ok = Health.validate_deployed_identity!(payload)

    assert :ok =
             Health.validate_deployed_identity(%{
               "release_id" => "v1.2.3-abc-42",
               "pipeline_id" => "42"
             })
  end

  test "reports every missing deployed identity field" do
    payload = %{release_id: "unknown", pipeline_id: "  "}

    assert {:error, [:release_id, :pipeline_id]} = Health.validate_deployed_identity(payload)

    assert_raise ArgumentError,
                 "deployed health identity is missing: release_id, pipeline_id",
                 fn -> Health.validate_deployed_identity!(payload) end
  end
end
