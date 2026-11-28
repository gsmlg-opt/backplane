defmodule Backplane.Skills.SearchCategories do
  @moduledoc "Operator-provided category hints for discovering searchable skills."

  alias Backplane.{Repo, Settings}
  alias Backplane.Settings.Setting

  @key "skills.search_categories"
  @max_categories 32
  @max_category_bytes 512
  @max_text_bytes 32_768
  @control_characters ~r/[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]/u

  @spec key() :: String.t()
  def key, do: @key

  @doc "Returns persisted category hints so reconnects also see changes from another replica."
  @spec list() :: [String.t()]
  def list do
    case Repo.get(Setting, @key) do
      %Setting{value: %{"v" => categories}} when is_list(categories) ->
        with true <- Enum.all?(categories, &is_binary/1),
             true <- Enum.reduce(categories, 0, &(byte_size(&1) + &2 + 1)) <= @max_text_bytes,
             {:ok, categories} <- parse(Enum.join(categories, "\n")) do
          categories
        else
          _ -> []
        end

      _ ->
        []
    end
  end

  @doc "Saves one category per line and returns the normalized string list."
  @spec save(String.t()) :: {:ok, [String.t()]} | {:error, term()}
  def save(text) do
    with {:ok, categories} <- parse(text),
         :ok <- Settings.set(@key, categories) do
      {:ok, categories}
    end
  end

  defp parse(text) when is_binary(text) do
    cond do
      byte_size(text) > @max_text_bytes ->
        {:error, :text_too_large}

      not String.valid?(text) or Regex.match?(@control_characters, text) ->
        {:error, :invalid_categories}

      true ->
        text
        |> String.split(~r/\r\n|\r|\n/u)
        |> Enum.map(&(String.trim(&1) |> String.replace("\t", " ")))
        |> Enum.reject(&(&1 == ""))
        |> Enum.uniq_by(&String.downcase/1)
        |> validate()
    end
  end

  defp parse(_text), do: {:error, :invalid_categories}

  defp validate(categories) do
    cond do
      length(categories) > @max_categories ->
        {:error, :too_many_categories}

      Enum.any?(categories, &(byte_size(&1) > @max_category_bytes)) ->
        {:error, :category_too_long}

      true ->
        {:ok, categories}
    end
  end
end
