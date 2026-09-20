defmodule Backplane.Monitor.ApiAccountTest do
  use ExUnit.Case, async: true

  alias Backplane.Monitor.ApiAccount

  test "API providers are independent of subscription providers" do
    assert ApiAccount.providers() == ~w(openrouter deepseek exa tavily firecrawl)
    assert ApiAccount.provider_label("openrouter") == "OpenRouter"
    assert ApiAccount.provider_label("deepseek") == "DeepSeek"
    assert ApiAccount.provider_label("exa") == "Exa"
    assert ApiAccount.provider_label("tavily") == "Tavily"
    assert ApiAccount.provider_label("firecrawl") == "Firecrawl"
  end

  test "requires a name, supported provider, and credential reference" do
    changeset = ApiAccount.changeset(%ApiAccount{}, %{})
    refute changeset.valid?
    assert Keyword.keys(changeset.errors) == [:name, :provider, :credential_name]

    refute ApiAccount.changeset(%ApiAccount{}, attrs(%{provider: "minimax"})).valid?
    assert ApiAccount.changeset(%ApiAccount{}, attrs()).valid?
  end

  test "management credentials are supported for OpenRouter and Exa" do
    assert ApiAccount.changeset(%ApiAccount{}, attrs(%{management_credential_name: "manager"})).valid?

    changeset =
      ApiAccount.changeset(
        %ApiAccount{},
        attrs(%{provider: "deepseek", management_credential_name: "manager"})
      )

    refute changeset.valid?
    assert changeset.errors[:management_credential_name]
  end

  test "does not cast secrets or arbitrary provider configuration" do
    changeset =
      ApiAccount.changeset(
        %ApiAccount{},
        attrs(%{api_key: "secret", config: %{url: "http://elsewhere"}})
      )

    refute Map.has_key?(changeset.changes, :api_key)
    refute Map.has_key?(changeset.changes, :config)
  end

  defp attrs(extra \\ %{}) do
    Map.merge(%{name: "Personal", provider: "openrouter", credential_name: "api-key"}, extra)
  end
end
