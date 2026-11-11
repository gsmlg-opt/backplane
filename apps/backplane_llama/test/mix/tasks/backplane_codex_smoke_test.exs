defmodule Mix.Tasks.Backplane.Codex.SmokeTest do
  use BackplaneLlama.DataCase, async: false

  import ExUnit.CaptureIO

  alias Backplane.LLM.{Provider, ProviderApi}
  alias Backplane.Settings.Credentials

  setup do
    HTTP.Test.verify_on_exit!()
    previous_api_url = Application.get_env(:backplane, :api_url)
    previous_http_options = Application.get_env(:backplane, :codex_smoke_http_options)
    previous_smoke = System.get_env("BACKPLANE_CODEX_SMOKE")
    previous_api_key = System.get_env("BACKPLANE_API_KEY")
    previous_client_version = System.get_env("OPENAI_CODEX_CLIENT_VERSION")

    Application.put_env(:backplane, :api_url, "https://backplane.test")

    Application.put_env(:backplane, :codex_smoke_http_options,
      adapter: {HTTP.Test, __MODULE__},
      retry: false
    )

    System.put_env("BACKPLANE_CODEX_SMOKE", "true")
    System.put_env("BACKPLANE_API_KEY", "backplane-client-token")
    System.put_env("OPENAI_CODEX_CLIENT_VERSION", "0.51.0")

    on_exit(fn ->
      restore_app_env(:api_url, previous_api_url)
      restore_app_env(:codex_smoke_http_options, previous_http_options)
      restore_system_env("BACKPLANE_CODEX_SMOKE", previous_smoke)
      restore_system_env("BACKPLANE_API_KEY", previous_api_key)
      restore_system_env("OPENAI_CODEX_CLIENT_VERSION", previous_client_version)
      Mix.Task.reenable("backplane.codex.smoke")
    end)

    expires_at = System.system_time(:millisecond) + 60 * 60 * 1_000

    {:ok, _credential} =
      Credentials.store_device_token(
        "codex-smoke-token",
        "openai_oauth",
        %{
          "type" => "codex_device_oauth",
          "id_token" => "codex-id-token",
          "access_token" => "upstream-token-must-not-be-used-by-smoke",
          "refresh_token" => "refresh-token",
          "expires_at" => expires_at
        },
        %{"account_id" => "acc-123"}
      )

    {:ok, provider} =
      Provider.create(%{
        name: "codex-smoke",
        preset_key: "openai-codex",
        credential: "codex-smoke-token",
        models: []
      })

    {:ok, _api} =
      ProviderApi.create(%{
        provider_id: provider.id,
        api_surface: :openai,
        base_url: "http://127.0.0.1:1/backend-api/codex"
      })

    :ok
  end

  test "routes model and response probes through the Backplane provider endpoint" do
    test_pid = self()

    HTTP.Test.stub(__MODULE__, fn request ->
      assert ["Bearer backplane-client-token"] =
               HTTP.Headers.get_all(request.headers, "authorization")

      refute Enum.any?(HTTP.Headers.to_list(request.headers), fn {_name, value} ->
               String.contains?(value, "upstream-token-must-not-be-used-by-smoke")
             end)

      case {request.method, request.url.path} do
        {:get, "/v1/providers/codex-smoke/models"} ->
          assert request.url.query == "client_version=0.51.0"
          send(test_pid, {:smoke_request, :models})

          HTTP.Test.response(200, Jason.encode!(%{"models" => [%{"slug" => "gpt-5.6-sol"}]}), [
            {"content-type", "application/json"},
            {"x-request-id", "req-models"}
          ])

        {:post, "/v1/providers/codex-smoke/responses"} ->
          decoded = Jason.decode!(IO.iodata_to_binary(request.body))
          assert decoded["model"] == "gpt-5.6-sol"

          cond do
            compaction_v2_request?(decoded) ->
              assert ["remote_compaction_v2"] =
                       HTTP.Headers.get_all(request.headers, "x-codex-beta-features")

              assert [
                       %{
                         "type" => "message",
                         "role" => "user",
                         "content" => [%{"type" => "input_text", "text" => _text}]
                       },
                       %{"type" => "compaction_trigger"}
                     ] = decoded["input"]

              assert decoded["stream"] == true
              send(test_pid, {:smoke_request, :compact_v2, decoded})

              event_stream(
                "req-compact-v2",
                ~s|event: response.output_item.done\ndata: {"type":"response.output_item.done","item":{"type":"compaction","encrypted_content":"summary"}}\n\nevent: response.completed\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n|
              )

            is_list(decoded["tools"]) and decoded["tools"] != [] ->
              assert_single_user_message(decoded)
              assert decoded["stream"] == true
              assert decoded["tool_choice"] == "required"
              send(test_pid, {:smoke_request, :responses, decoded})

              event_stream(
                "req-tool-call",
                ~s|event: response.output_item.done\ndata: {"type":"response.output_item.done","item":{"type":"function_call","name":"smoke_probe","call_id":"call-smoke","arguments":"{}"}}\n\nevent: response.completed\ndata: {"type":"response.completed","response":{"status":"completed"}}\n\n|
              )

            input_text(decoded) == "Respond with the word: streamed-ok" ->
              assert_single_user_message(decoded)
              send(test_pid, {:smoke_request, :responses, decoded})

              event_stream(
                "req-stream",
                ~s|event: response.created\ndata: {"type":"response.created"}\n\nevent: response.completed\ndata: {"type":"response.completed"}\n\n|
              )

            true ->
              assert_single_user_message(decoded)
              send(test_pid, {:smoke_request, :responses, decoded})

              event_stream(
                "req-response",
                ~s|event: response.created\ndata: {"type":"response.created"}\n\nevent: response.completed\ndata: {"type":"response.completed"}\n\n|
              )
          end

        unexpected ->
          flunk("unexpected smoke request: #{inspect(unexpected)}")
      end
    end)

    output =
      capture_io(fn ->
        Mix.Tasks.Backplane.Codex.Smoke.run([
          "--provider",
          "codex-smoke",
          "--model",
          "gpt-5.6-sol"
        ])
      end)

    assert output =~ "models status=200"
    assert output =~ "req-models"
    assert output =~ "responses status=200"
    assert output =~ "req-response"
    assert output =~ "stream status=200"
    assert output =~ "event_count=2"
    assert output =~ "req-stream"
    assert output =~ "tool_call status=200"
    assert output =~ "tool_calls=1"
    assert output =~ "req-tool-call"
    assert output =~ "compact_v2 status=200"
    assert output =~ "output_items=1"
    assert output =~ "req-compact-v2"

    assert_receive {:smoke_request, :models}
    assert_receive {:smoke_request, :responses, %{"stream" => true, "tools" => []}}

    assert_receive {:smoke_request, :responses,
                    %{"stream" => true, "tools" => [%{"name" => "smoke_probe"}]}}

    assert_receive {:smoke_request, :responses, %{"stream" => true}}

    assert_receive {:smoke_request, :compact_v2,
                    %{
                      "stream" => true,
                      "input" => [_message, %{"type" => "compaction_trigger"}]
                    }}

    refute output =~ "backplane-client-token"
    refute output =~ "upstream-token-must-not-be-used-by-smoke"
  end

  test "fails instead of reporting success when an upstream probe is not successful" do
    HTTP.Test.stub(__MODULE__, fn _request ->
      HTTP.Test.response(502, Jason.encode!(%{"error" => "upstream unavailable"}), [
        {"content-type", "application/json"},
        {"x-request-id", "req-upstream-failure"}
      ])
    end)

    assert_raise Mix.Error, ~r/models failed with status 502/, fn ->
      capture_io(fn ->
        Mix.Tasks.Backplane.Codex.Smoke.run([
          "--provider",
          "codex-smoke",
          "--model",
          "gpt-5.6-sol"
        ])
      end)
    end
  end

  defp event_stream(request_id, body) do
    HTTP.Test.response(200, body, [
      {"content-type", "text/event-stream"},
      {"x-request-id", request_id}
    ])
  end

  defp restore_app_env(key, nil), do: Application.delete_env(:backplane, key)
  defp restore_app_env(key, value), do: Application.put_env(:backplane, key, value)

  defp restore_system_env(key, nil), do: System.delete_env(key)
  defp restore_system_env(key, value), do: System.put_env(key, value)

  defp input_text(%{
         "input" => [
           %{"content" => [%{"type" => "input_text", "text" => text}]}
         ]
       }),
       do: text

  defp compaction_v2_request?(%{"input" => input}) when is_list(input),
    do: Enum.any?(input, &match?(%{"type" => "compaction_trigger"}, &1))

  defp compaction_v2_request?(_request), do: false

  defp assert_single_user_message(decoded) do
    assert [
             %{
               "type" => "message",
               "role" => "user",
               "content" => [%{"type" => "input_text", "text" => _text}]
             }
           ] = decoded["input"]
  end
end
