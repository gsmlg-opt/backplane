defmodule Backplane.SkillProtocol.DocumentTest do
  use ExUnit.Case, async: true

  alias Backplane.SkillProtocol.{Eligibility, Error, Parser, Validator}

  test "preserves exact CRLF source, multiline metadata, nested extensions, and typed booleans" do
    bytes =
      "---\r\nname: example-skill\r\ndescription: |\r\n  First line\r\n  Second line\r\ndisable-model-invocation: true # manual only\r\nx-owner:\r\n  team: runtime\r\n---\r\nBody\r\n"

    assert {:ok, document} = Parser.parse(bytes)
    assert document.raw == bytes
    assert document.body_raw == "Body\r\n"
    assert document.description == "First line\nSecond line\n"
    assert document.metadata["disable-model-invocation"] == true
    assert document.extensions == %{"x-owner" => %{"team" => "runtime"}}
    assert {:ok, _} = Validator.validate(document)
  end

  test "accepts a UTF-8 BOM without rewriting original bytes" do
    bytes = <<0xEF, 0xBB, 0xBF>> <> "---\nname: example-skill\ndescription: Example\n---\nBody"
    assert {:ok, document} = Parser.parse(bytes)
    assert document.raw == bytes
  end

  test "rejects duplicate keys at any nesting level" do
    top = "---\nname: one\nname: two\ndescription: Example\n---\nBody"
    nested = "---\nname: one\ndescription: Example\nx:\n  key: one\n  key: two\n---\nBody"
    assert {:error, %Error{code: :duplicate_key}} = Parser.parse(top)
    assert {:error, %Error{code: :duplicate_key}} = Parser.parse(nested)
  end

  test "rejects malformed encoding, document size, frontmatter size, and nesting deterministically" do
    assert {:error, %Error{code: :invalid_encoding}} = Parser.parse(<<255>>)

    bytes = "---\nname: example\ndescription: Example\n---\nBody"
    assert {:error, %Error{code: :limit_exceeded}} = Parser.parse(bytes, max_document_bytes: 8)
    assert {:error, %Error{code: :limit_exceeded}} = Parser.parse(bytes, max_frontmatter_bytes: 8)

    nested = "---\nname: example\ndescription: Example\nx:\n  y:\n    z: value\n---\nBody"
    assert {:error, %Error{code: :limit_exceeded}} = Parser.parse(nested, max_nesting_depth: 1)
  end

  test "strict and legacy validation remain distinct and never fabricate description" do
    bytes = "---\nname: legacy-skill\n---\nBody"
    assert {:ok, document} = Parser.parse(bytes)
    assert document.description == nil
    assert {:error, %Error{code: :invalid_document}} = Validator.validate(document)
    assert {:ok, legacy} = Validator.validate(document, profile: :legacy)
    assert legacy.description == nil
    assert [%{code: :missing_description, severity: :warning}] = legacy.diagnostics
  end

  test "malformed invocation flags and unsupported mandatory capabilities fail closed" do
    malformed =
      "---\nname: example\ndescription: Example\ndisable-model-invocation: \"true\"\n---\nBody"

    assert {:ok, document} = Parser.parse(malformed)
    assert {:error, %Error{context: %{diagnostics: diagnostics}}} = Validator.validate(document)
    assert Enum.any?(diagnostics, &(&1.code == :invalid_invocation_flag))

    required =
      "---\nname: example\ndescription: Example\nbackplane:\n  required-capabilities: [network]\n---\nBody"

    assert {:ok, document} = Parser.parse(required)
    assert {:error, %Error{context: %{diagnostics: diagnostics}}} = Validator.validate(document)
    assert Enum.any?(diagnostics, &(&1.code == :unsupported_capability))
    assert {:ok, _} = Validator.validate(document, supported_capabilities: ["network"])
  end

  test "manual-only and host-disabled eligibility are separate and grant no tools" do
    bytes = "---\nname: example\ndescription: Example\ndisable-model-invocation: true\n---\nBody"
    assert {:ok, document} = Parser.parse(bytes)

    assert {:error, %Error{code: :manual_only}} =
             Eligibility.evaluate(document, :automatic, %{enabled: true})

    assert {:ok, :eligible} = Eligibility.evaluate(document, :explicit, %{enabled: true})

    assert {:error, %Error{code: :host_disabled}} =
             Eligibility.evaluate(document, :explicit, %{enabled: false})

    refute Map.has_key?(document.metadata, "granted-tools")
  end
end
