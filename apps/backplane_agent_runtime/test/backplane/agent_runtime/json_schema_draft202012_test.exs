defmodule Backplane.AgentRuntime.JSONSchemaDraft202012Test do
  use ExUnit.Case, async: false

  @suite_root Path.expand("../../fixtures/json_schema_test_suite", __DIR__)
  @suite_commit "5b0ee1613e45fcc2bddac00e07c19cd49b00d8a8"
  @draft_root Path.join(@suite_root, "draft2020-12")
  @remote_root Path.join(@suite_root, "remotes/draft2020-12")
  @remote_base "http://localhost:1234/draft2020-12/"

  test "runs the required Draft 2020-12 official test suite at a fixed commit" do
    assert File.read!(Path.join(@suite_root, "COMMIT")) |> String.trim() == @suite_commit

    files =
      @draft_root
      |> Path.join("**/*.json")
      |> Path.wildcard()
      |> Enum.reject(&String.contains?(&1, "/optional/"))
      |> Enum.sort()

    refute files == []

    Enum.each(files, fn file ->
      file
      |> File.read!()
      |> JSON.decode!()
      |> case do
        groups when is_list(groups) -> Enum.each(groups, &run_group(&1, file, []))
        _remote_document -> :ok
      end
    end)
  end

  test "keeps format and content assertions annotation-only by default" do
    {:ok, schema} =
      JSONSchex.compile(%{
        "$schema" => "https://json-schema.org/draft/2020-12/schema",
        "type" => "string",
        "format" => "email",
        "contentEncoding" => "base64",
        "contentMediaType" => "application/json"
      })

    assert :ok = JSONSchex.validate(schema, "not-an-email")
  end

  test "supports opt-in format assertion without changing the default policy" do
    {:ok, schema} =
      JSONSchex.compile(
        %{
          "$schema" => "https://json-schema.org/draft/2020-12/schema",
          "type" => "string",
          "format" => "email"
        },
        format_assertion: true
      )

    assert {:error, errors} = JSONSchex.validate(schema, "not-an-email")
    assert Enum.any?(errors, &(&1.rule == :format))
  end

  defp run_group(%{"schema" => schema, "tests" => tests, "description" => group}, file, opts) do
    {:ok, compiled} = JSONSchex.compile(schema, Keyword.put(opts, :loader, &load_remote/1))

    Enum.each(tests, fn %{"data" => data, "valid" => expected, "description" => description} ->
      actual = JSONSchex.validate(compiled, data) == :ok

      assert actual == expected,
             "#{Path.relative_to(file, @suite_root)} / #{group} / #{description}"
    end)
  end

  defp load_remote(uri) do
    case remote_file(uri) do
      nil -> {:error, {:remote_fixture_not_found, uri}}
      file -> {:ok, file |> File.read!() |> JSON.decode!()}
    end
  end

  defp remote_file(uri) do
    path = String.replace_prefix(uri, @remote_base, "")
    candidate = Path.join(@remote_root, path)

    cond do
      File.regular?(candidate) -> candidate
      String.starts_with?(uri, "urn:") -> Path.join(@remote_root, "urn-ref-string.json")
      true -> nil
    end
  end
end
