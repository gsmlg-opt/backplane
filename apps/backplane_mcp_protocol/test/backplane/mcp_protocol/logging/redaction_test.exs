defmodule Backplane.McpProtocol.Logging.RedactionTest do
  use ExUnit.Case, async: true

  alias Backplane.McpProtocol.Logging.Redaction

  defmodule SecretStruct do
    @moduledoc false
    defstruct [:client_secret, :label]
  end

  @redacted "[REDACTED]"

  test "redacts sensitive map, struct, keyword, header, and tuple values recursively" do
    value = %{
      "Authorization" => "Bearer map-secret",
      :proxy_authorization => "Basic proxy-secret",
      "MCP-PARAM-City" => "Paris",
      nested: [
        access_token: "access-secret",
        refresh_token: "refresh-secret",
        arbitrary: {:tag, {:client_assertion, "assertion-secret"}}
      ],
      struct: struct(SecretStruct, client_secret: "struct-secret", label: "safe"),
      headers: [{"mcp_param_region", "west"}, {"content-type", "application/json"}]
    }

    assert %{
             "Authorization" => @redacted,
             :proxy_authorization => @redacted,
             "MCP-PARAM-City" => @redacted,
             nested: [
               access_token: @redacted,
               refresh_token: @redacted,
               arbitrary: {:tag, {:client_assertion, @redacted}}
             ],
             struct: %SecretStruct{client_secret: @redacted, label: "safe"},
             headers: [
               {"mcp_param_region", @redacted},
               {"content-type", "application/json"}
             ]
           } = Redaction.redact(value)
  end

  test "normalizes sensitive keys without creating atoms" do
    values = %{
      "ACCESS-TOKEN" => "one",
      "token" => "zero",
      "proxyAuthorization" => "proxy",
      "refresh_token" => "two",
      "Id-Token" => "three",
      "bearerToken" => "four",
      "registration-access-token" => "five",
      "client-secret" => "six",
      "ASSERTION" => "seven",
      "Code-Verifier" => "eight",
      "authorization_code" => "nine",
      "requestState" => "ten"
    }

    assert values
           |> Redaction.redact()
           |> Map.values()
           |> Enum.uniq() == [@redacted]

    unknown_key = "redaction_must_not_atomize_#{System.unique_integer([:positive])}"
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end
    assert %{^unknown_key => "safe"} = Redaction.redact(%{unknown_key => "safe"})
    assert_raise ArgumentError, fn -> String.to_existing_atom(unknown_key) end
  end

  test "redacts string authorization codes while preserving numeric JSON-RPC codes" do
    assert %{
             "string" => %{"code" => @redacted},
             "integer" => %{"code" => -32_600},
             "float" => %{"code" => 1.5}
           } =
             Redaction.redact(%{
               "string" => %{"code" => "authorization-code-secret"},
               "integer" => %{"code" => -32_600},
               "float" => %{"code" => 1.5}
             })
  end

  test "preserves identifiers, challenges, scopes, URLs, methods, and measurements" do
    safe = %{
      "client_id" => "public-client",
      "token_type" => "Bearer",
      "expires_in" => 3_600,
      "code_challenge" => "challenge",
      "progressToken" => "progress-1",
      "scope" => "read write",
      "scopes" => ["read", "write"],
      "issuer" => "https://issuer.example",
      "resource" => "https://resource.example/mcp",
      "method" => "tools/call",
      "id" => 17,
      "duration" => 42
    }

    assert Redaction.redact(safe) == safe
  end

  test "walks proper and improper lists and arbitrary tuples" do
    improper = [{:access_token, "list-secret"} | {:client_secret, "tail-secret"}]
    tuple = {:outer, {:inner, %{authorization_code: "tuple-secret"}}, self(), make_ref()}

    assert [{:access_token, @redacted} | {:client_secret, @redacted}] =
             Redaction.redact(improper)

    assert {:outer, {:inner, %{authorization_code: @redacted}}, pid, ref} =
             Redaction.redact(tuple)

    assert pid == self()
    assert is_reference(ref)
  end

  test "redacts credentials split across chardata and iodata boundaries" do
    assert Redaction.redact(["Bearer ", "split-secret"]) == "Bearer [REDACTED]"
    assert Redaction.redact(["Basic ", ["nested-secret"]]) == "Basic [REDACTED]"
    assert Redaction.redact(~c"Bearer charlist-secret") == "Bearer [REDACTED]"

    assert %{"note" => "Bearer [REDACTED]"} =
             Redaction.redact(%{"note" => ["Bearer ", "metadata-secret"]})
  end

  test "redacts credentials embedded in map keys and MapSet members" do
    value = %{
      "Bearer map-key-secret" => :present,
      set: MapSet.new(["safe", "Bearer set-member-secret"])
    }

    redacted = Redaction.redact(value)

    assert redacted["Bearer [REDACTED]"] == :present
    assert redacted.set == MapSet.new(["safe", "Bearer [REDACTED]"])
    refute inspect(redacted) =~ "map-key-secret"
    refute inspect(redacted) =~ "set-member-secret"
  end

  test "classifies chardata map and tuple keys before redacting their values" do
    token_key = ~c"token"

    assert %{^token_key => @redacted} =
             Redaction.redact(%{token_key => "char-key-secret"})

    assert {^token_key, @redacted} = Redaction.redact({token_key, "tuple-char-key-secret"})
  end

  test "sanitizes JSON, duplicate form fields, raw headers, and embedded credentials" do
    json =
      ~s({"client_id":"safe","access_token":"json-secret","error":{"code":-32600},"oauth":{"code":"code-secret"}})

    assert %{
             "client_id" => "safe",
             "access_token" => @redacted,
             "error" => %{"code" => -32_600},
             "oauth" => %{"code" => @redacted}
           } = json |> Redaction.redact() |> JSON.decode!()

    form = "scope=read&client_secret=form-one&scope=write&client_secret=form-two"

    assert Redaction.redact(form) ==
             "scope=read&client_secret=[REDACTED]&scope=write&client_secret=[REDACTED]"

    assert Redaction.redact("token=oauth-token-secret&token_type=Bearer") ==
             "token=[REDACTED]&token_type=Bearer"

    headers =
      "Content-Type: application/json\r\nAuthorization: Bearer header-secret\r\n" <>
        "Mcp-Param-City: Paris\r\nX-Safe: visible"

    redacted_headers = Redaction.redact(headers)
    assert redacted_headers =~ "Content-Type: application/json"
    assert redacted_headers =~ "Authorization: [REDACTED]"
    assert redacted_headers =~ "Mcp-Param-City: [REDACTED]"
    assert redacted_headers =~ "X-Safe: visible"
    refute redacted_headers =~ "header-secret"
    refute redacted_headers =~ "Paris"

    assert Redaction.redact("request failed with Bearer embedded-secret") ==
             "request failed with Bearer [REDACTED]"

    assert Redaction.redact("Basic Zm9vOmJhcg==") == "Basic [REDACTED]"
  end

  test "fails closed for malformed sensitive binaries without changing harmless binaries" do
    malformed = [
      {~s({"access_token":"malformed-json-secret"), "malformed-json-secret"},
      {~s({"access_token" "missing-colon-secret"}), "missing-colon-secret"},
      {~s({"access\u005ftoken" "escaped-key-secret"}), "escaped-key-secret"},
      {~s({access_token "unquoted-key-secret"}), "unquoted-key-secret"},
      {"client_secret=%ZZmalformed-form-secret", "malformed-form-secret"},
      {"Authorization Bearer malformed-header-secret", "malformed-header-secret"},
      {"Authorization:\r\n folded-header-secret", "folded-header-secret"},
      {"?%63ode=query-code-secret", "query-code-secret"},
      {"?%63lient_secret=query-client-secret", "query-client-secret"},
      {"Bearer\ttab-secret", "tab-secret"}
    ]

    for {value, secret} <- malformed do
      redacted = Redaction.redact(value)
      assert redacted =~ @redacted
      refute redacted =~ secret
    end

    for harmless <- [
          "plain text",
          ~s({ "method" : "tools/list", "id" : 1 }),
          "scope=read&scope=write",
          "X-Safe: visible"
        ] do
      assert Redaction.redact(harmless) == harmless
    end
  end

  test "is total for invalid UTF-8 and unusual terms" do
    invalid_harmless = <<"plain", 255>>
    invalid_sensitive = <<"Bearer invalid-secret", 255>>
    invalid_code = <<"code=invalid-auth-code", 255>>
    invalid_tab = <<"Bearer\tinvalid-tab-secret", 255>>
    fun = fn -> :ok end
    ref = make_ref()

    assert Redaction.redact(invalid_harmless) == invalid_harmless
    assert Redaction.redact(invalid_sensitive) == @redacted
    assert Redaction.redact(invalid_code) == @redacted
    assert Redaction.redact(invalid_tab) == @redacted
    assert Redaction.redact(fun) === fun
    assert Redaction.redact(self()) == self()
    assert Redaction.redact(ref) == ref
  end

  test "is idempotent across all supported shapes" do
    value = %{
      authorization: "Bearer secret",
      body: ~s({"refresh_token":"secret"}),
      form: "client_secret=secret&scope=read",
      headers: "Mcp-Param-City: Paris\r\nX-Safe: yes",
      improper: [{:code, "secret"} | {:id_token, "secret"}]
    }

    once = Redaction.redact(value)
    assert Redaction.redact(once) == once
  end
end
