defmodule Backplane.LLM.ModelAlias do
  @moduledoc """
  Settings-backed custom LLM model aliases.

  Built-in aliases such as `fast`, `smart`, and `expert` are owned by
  `Backplane.LLM.AutoModel`. Custom aliases are one-to-one pointers to either a
  built-in alias or a concrete provider model id.
  """

  use Ecto.Schema
  import Ecto.Changeset

  alias Backplane.LLM.AutoModel
  alias Backplane.Settings

  @type t :: %__MODULE__{
          alias: String.t(),
          target: String.t()
        }

  @primary_key false
  embedded_schema do
    field(:alias, :string)
    field(:target, :string)
  end

  @setting_key "llm.model_aliases.custom"

  @doc "Return the settings key used to persist custom model aliases."
  @spec setting_key() :: String.t()
  def setting_key, do: @setting_key

  @doc "Changeset for custom model aliases."
  @spec changeset(t(), map()) :: Ecto.Changeset.t()
  def changeset(model_alias, attrs) do
    model_alias
    |> cast(normalize_attrs(attrs), [:alias, :target])
    |> update_change(:alias, &trim_string/1)
    |> update_change(:target, &trim_string/1)
    |> validate_required([:alias, :target])
    |> validate_format(:alias, ~r/^[^\/]+$/, message: "must not contain /")
    |> validate_exclusion(:alias, AutoModel.built_in_names(), message: "is built in")
    |> validate_alias_target()
  end

  @doc "List custom aliases ordered by alias."
  @spec list() :: [t()]
  def list do
    @setting_key
    |> Settings.get()
    |> normalize_alias_map()
    |> Enum.map(fn {alias_name, target} ->
      %__MODULE__{alias: alias_name, target: target}
    end)
    |> Enum.sort_by(& &1.alias)
  end

  @doc "Fetch a custom alias by name."
  @spec get(String.t()) :: t() | nil
  def get(alias_name) when is_binary(alias_name) do
    alias_name = String.trim(alias_name)

    @setting_key
    |> Settings.get()
    |> normalize_alias_map()
    |> Map.get(alias_name)
    |> case do
      nil -> nil
      target -> %__MODULE__{alias: alias_name, target: target}
    end
  end

  @doc "Create or replace a custom alias."
  @spec create(map()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) when is_map(attrs) do
    put_changeset(changeset(%__MODULE__{}, attrs))
  end

  @doc "Create or replace a custom alias."
  @spec put(String.t(), String.t()) :: {:ok, t()} | {:error, Ecto.Changeset.t()}
  def put(alias_name, target) when is_binary(alias_name) and is_binary(target) do
    create(%{alias: alias_name, target: target})
  end

  @doc "Delete a custom alias."
  @spec delete(t() | String.t()) :: {:ok, t()} | {:error, :not_found | term()}
  def delete(%__MODULE__{alias: alias_name}), do: delete(alias_name)

  def delete(alias_name) when is_binary(alias_name) do
    alias_name = String.trim(alias_name)
    aliases = Settings.get(@setting_key) |> normalize_alias_map()

    case Map.pop(aliases, alias_name) do
      {nil, _aliases} ->
        {:error, :not_found}

      {target, aliases} ->
        with :ok <- Settings.set(@setting_key, aliases) do
          broadcast()
          {:ok, %__MODULE__{alias: alias_name, target: target}}
        end
    end
  end

  @doc "Return a custom alias target, if configured."
  @spec target_for(String.t()) :: String.t() | nil
  def target_for(alias_name) when is_binary(alias_name) do
    case get(alias_name) do
      %__MODULE__{target: target} -> target
      nil -> nil
    end
  end

  defp put_changeset(%Ecto.Changeset{valid?: false} = changeset), do: {:error, changeset}

  defp put_changeset(%Ecto.Changeset{} = changeset) do
    model_alias = apply_changes(changeset)

    aliases =
      @setting_key
      |> Settings.get()
      |> normalize_alias_map()
      |> Map.put(model_alias.alias, model_alias.target)

    with :ok <- Settings.set(@setting_key, aliases) do
      broadcast()
      {:ok, model_alias}
    end
  end

  defp normalize_attrs(attrs) do
    %{
      alias: Map.get(attrs, :alias) || Map.get(attrs, "alias"),
      target:
        Map.get(attrs, :target) || Map.get(attrs, "target") || Map.get(attrs, :model) ||
          Map.get(attrs, "model")
    }
  end

  defp normalize_alias_map(aliases) when is_map(aliases) do
    Enum.reduce(aliases, %{}, fn
      {alias_name, target}, acc when is_binary(alias_name) and is_binary(target) ->
        alias_name = String.trim(alias_name)
        target = String.trim(target)

        if alias_name == "" or target == "" do
          acc
        else
          Map.put(acc, alias_name, target)
        end

      _entry, acc ->
        acc
    end)
  end

  defp normalize_alias_map(_aliases), do: %{}

  defp validate_alias_target(%Ecto.Changeset{valid?: false} = changeset), do: changeset

  defp validate_alias_target(changeset) do
    alias_name = get_field(changeset, :alias)
    target = get_field(changeset, :target)

    if alias_name == target do
      add_error(changeset, :target, "must be different from alias")
    else
      changeset
    end
  end

  defp trim_string(value) when is_binary(value), do: String.trim(value)
  defp trim_string(value), do: value

  defp broadcast do
    Backplane.PubSubBroadcaster.broadcast_llm_providers(:llm_providers_changed, %{})
  end
end
