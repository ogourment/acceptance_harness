defmodule AcceptanceHarness.DeploymentTest do
  use ExUnit.Case, async: false

  alias AcceptanceHarness.Deployment

  @env_names ~w(
    TEST_APP_APP_VERSION
    TEST_APP_RELEASE_ID
    TEST_APP_DISPLAY_ENV
    TEST_APP_COLOR
    TEST_APP_CI_PIPELINE_ID
    TEST_APP_GIT_SHA
    TEST_APP_GIT_REF
    TEST_APP_GIT_MESSAGES
  )

  setup do
    previous_env = Map.new(@env_names, &{&1, System.get_env(&1)})
    previous_config = Application.get_env(:acceptance_harness, :deployment)

    on_exit(fn ->
      Enum.each(previous_env, fn
        {name, nil} -> System.delete_env(name)
        {name, value} -> System.put_env(name, value)
      end)

      if previous_config do
        Application.put_env(:acceptance_harness, :deployment, previous_config)
      else
        Application.delete_env(:acceptance_harness, :deployment)
      end
    end)
  end

  test "builds current deployment metadata from the shared environment prefix" do
    System.put_env("TEST_APP_APP_VERSION", "1.4.2")
    System.put_env("TEST_APP_RELEASE_ID", "v1.4.2-abcdef12-88")
    System.put_env("TEST_APP_DISPLAY_ENV", "staging")
    System.put_env("TEST_APP_COLOR", "green")
    System.put_env("TEST_APP_CI_PIPELINE_ID", "88")
    System.put_env("TEST_APP_GIT_SHA", "abcdef1234567890")
    System.put_env("TEST_APP_GIT_REF", "main")
    System.put_env("TEST_APP_GIT_MESSAGES", "Add versions page\\nLink acceptance evidence")

    current = Deployment.current(otp_app: :acceptance_harness, env_prefix: "TEST_APP")

    assert current["app_version"] == "1.4.2"
    assert current["release_id"] == "v1.4.2-abcdef12-88"
    assert current["environment"] == "staging"
    assert current["slot"] == "green"
    assert current["pipeline_id"] == "88"
    assert current["git_sha"] == "abcdef1234567890"
    assert current["git_ref"] == "main"
    assert current["git_messages"] == ["Add versions page", "Link acceptance evidence"]
    assert current["current"]
  end

  test "reads JSONL history newest first and ignores malformed lines" do
    path =
      Path.join(
        System.tmp_dir!(),
        "acceptance-deployments-#{System.unique_integer([:positive])}.jsonl"
      )

    File.write!(path, [
      Jason.encode!(%{
        "app_version" => "1.0.0",
        "git_sha" => "aaaa",
        "git_messages" => ["First"]
      }),
      "\nnot-json\n",
      Jason.encode!(%{
        "app_version" => "1.1.0",
        "git_sha" => "bbbb",
        "git_messages" => ["Second"]
      }),
      "\n"
    ])

    on_exit(fn -> File.rm(path) end)

    assert [newest, oldest] = Deployment.history(history_path: path)
    assert newest["app_version"] == "1.1.0"
    assert oldest["app_version"] == "1.0.0"
  end

  test "searches partial commit hashes and commit messages before paginating" do
    rows =
      for number <- 1..12 do
        %{
          "app_version" => "1.#{number}.0",
          "release_id" => "release-#{number}",
          "git_sha" => if(number == 7, do: "abcDEF7890", else: "sha#{number}"),
          "git_messages" => [
            if(number == 9, do: "Repair invitation audit trail", else: "Change #{number}")
          ]
        }
      end

    page = Deployment.paginate(rows, %{"page" => "2", "page_size" => "5"})
    assert page.page == 2
    assert page.total == 12
    assert Enum.map(page.rows, & &1["release_id"]) == Enum.map(6..10, &"release-#{&1}")

    sha_match = Deployment.paginate(rows, %{"q" => "def78"})
    assert Enum.map(sha_match.rows, & &1["release_id"]) == ["release-7"]

    message_match = Deployment.paginate(rows, %{"q" => "INVITATION audit"})
    assert Enum.map(message_match.rows, & &1["release_id"]) == ["release-9"]
  end

  test "uses configurable providers for current and historical deployments" do
    current_provider = fn ->
      %{
        version: "2.0.0",
        env: "staging",
        color: "blue",
        git_sha: "current-sha",
        git_subject: "Normalize provider metadata"
      }
    end

    history_provider = fn -> [%{"app_version" => "1.9.0", "git_sha" => "old-sha"}] end

    current = Deployment.current(current_provider: current_provider)
    assert current["app_version"] == "2.0.0"
    assert current["environment"] == "staging"
    assert current["slot"] == "blue"
    assert current["git_messages"] == ["Normalize provider metadata"]
    assert [%{"app_version" => "1.9.0"}] = Deployment.history(history_provider: history_provider)
  end
end
