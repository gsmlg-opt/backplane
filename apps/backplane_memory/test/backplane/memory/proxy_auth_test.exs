defmodule Backplane.Memory.ProxyAuthTest do
  use Backplane.Memory.DataCase, async: false

  alias Backplane.Memory.Embedding.Client
  alias Backplane.Settings.Credentials

  setup do
    keys = ["memory.proxy_credential", "memory.llm_model"]
    snapshot = Map.new(keys, &{&1, :ets.lookup(:backplane_settings, &1)})

    on_exit(fn ->
      Enum.each(snapshot, fn {key, rows} ->
        :ets.delete(:backplane_settings, key)
        if rows != [], do: :ets.insert(:backplane_settings, rows)
      end)
    end)

    :ets.insert(:backplane_settings, {"memory.llm_model", "synthetic-model"})
    HTTP.Test.verify_on_exit!()
    :ok
  end

  test "embedding requests authenticate using a named vault service credential" do
    name = "memory-proxy-#{System.unique_integer([:positive])}"
    assert {:ok, _} = Credentials.store(name, "synthetic-resource-token", "service")
    :ets.insert(:backplane_settings, {"memory.proxy_credential", name})

    HTTP.Test.stub(__MODULE__, fn request ->
      assert HTTP.Headers.get_all(request.headers, "authorization") == [
               "Bearer synthetic-resource-token"
             ]

      assert HTTP.Headers.get_all(request.headers, "x-backplane-memory-capture") == ["skip"]

      HTTP.Test.json(%{"data" => [%{"index" => 0, "embedding" => List.duplicate(0.1, 2560)}]})
    end)

    assert {:ok, [_]} =
             Client.embed(["alpha"], :document,
               model: "embedding",
               http_options: [adapter: {HTTP.Test, __MODULE__}]
             )
  end

  test "an unavailable configured credential fails before sending the provider request" do
    :ets.insert(:backplane_settings, {"memory.proxy_credential", "missing-memory-resource-token"})

    HTTP.Test.stub(__MODULE__, fn _request ->
      flunk("must not send an unauthenticated request")
    end)

    assert {:error, :proxy_credential_unavailable} =
             Client.embed(["alpha"], :document,
               model: "embedding",
               http_options: [adapter: {HTTP.Test, __MODULE__}]
             )
  end
end
