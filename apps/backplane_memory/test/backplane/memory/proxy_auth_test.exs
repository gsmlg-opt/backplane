defmodule Backplane.Memory.ProxyAuthTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.{Embedding.Client, LLM}
  alias Backplane.Settings.Credentials

  setup do
    keys = ["memory.proxy_credential", "memory.llm_model"]
    snapshot = Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})
    previous_options = Application.get_env(:backplane_memory, :llm_req_options)

    on_exit(fn ->
      Enum.each(snapshot, fn {key, rows} ->
        :ets.delete(:backplane_settings, key)
        if rows != [], do: :ets.insert(:backplane_settings, rows)
      end)

      if previous_options,
        do: Application.put_env(:backplane_memory, :llm_req_options, previous_options),
        else: Application.delete_env(:backplane_memory, :llm_req_options)
    end)

    :ets.insert(:backplane_settings, {"memory.llm_model", "synthetic-model"})
    :ok
  end

  test "LLM and embedding requests authenticate using a named vault service credential" do
    name = "memory-proxy-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Credentials.store(name, "synthetic-resource-token", "service")
    :ets.insert(:backplane_settings, {"memory.proxy_credential", name})

    adapter = fn req ->
      assert Req.Request.get_header(req, "authorization") == ["Bearer synthetic-resource-token"]
      assert Req.Request.get_header(req, "x-backplane-memory-capture") == ["skip"]
      assert LLM.capture_suppressed?()

      body =
        if String.ends_with?(req.url.path, "/embeddings"),
          do: %{"data" => [%{"index" => 0, "embedding" => List.duplicate(0.1, 2560)}]},
          else: %{
            "choices" => [
              %{
                "message" => %{
                  "content" => Jason.encode!(%{"queries" => ["alpha beta", "beta alpha"]})
                }
              }
            ]
          }

      {req, Req.Response.new(status: 200, body: body)}
    end

    Application.put_env(:backplane_memory, :llm_req_options, adapter: adapter)
    assert {:ok, _} = LLM.expand_query("alpha")

    assert {:ok, [_]} =
             Client.embed(["alpha"], :document,
               model: "embedding",
               req_options: [adapter: adapter]
             )
  end

  test "an unavailable configured credential fails before sending either provider request" do
    :ets.insert(:backplane_settings, {"memory.proxy_credential", "missing-memory-resource-token"})
    adapter = fn _req -> flunk("must not send an unauthenticated request") end
    Application.put_env(:backplane_memory, :llm_req_options, adapter: adapter)

    assert {:error, :proxy_credential_unavailable} = LLM.expand_query("alpha")

    assert {:error, :proxy_credential_unavailable} =
             Client.embed(["alpha"], :document,
               model: "embedding",
               req_options: [adapter: adapter]
             )

    refute LLM.capture_suppressed?()
  end
end
