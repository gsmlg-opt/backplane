defmodule Backplane.Endpoints.Endpoint do
  @moduledoc """
  Named endpoint surface restricting MCP prefixes, LLM models and clients.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]

  @type t :: %__MODULE__{}

  @forbidden_prefixes ["admin", "hub", "skill", "system"]
  @name_format ~r/\A[a-z0-9][a-z0-9-]{0,62}\z/
  @prefix_format ~r/\A[\w-]+\z/

  @doc "True when `name` is a valid endpoint name."
  @spec valid_name?(term()) :: boolean()
  def valid_name?(name) when is_binary(name), do: Regex.match?(@name_format, name)
  def valid_name?(_name), do: false

  schema "endpoints" do
    field(:name, :string)
    field(:description, :string)
    field(:enabled, :boolean, default: true)
    field(:mcp_enabled, :boolean, default: false)
    field(:llm_enabled, :boolean, default: false)
    field(:mcp_prefixes, {:array, :string}, default: [])
    field(:models, {:array, :string}, default: [])
    field(:restrict_clients, :boolean, default: false)
    field(:oauth_client_ids, {:array, :string}, default: [])
    field(:client_ids, {:array, Ecto.UUID}, default: [])

    timestamps()
  end

  @editable ~w(description mcp_enabled llm_enabled mcp_prefixes models restrict_clients
               oauth_client_ids client_ids)a

  @doc false
  def forbidden_prefixes, do: @forbidden_prefixes

  @doc "Changeset for creation; the only one that accepts `name` and `enabled`."
  def create_changeset(endpoint, attrs) do
    endpoint
    |> cast(attrs, [:name, :enabled | @editable])
    |> validate_required([:name])
    |> validate_name()
    |> validate_settings()
  end

  @doc "Changeset for edits; `name` and `enabled` are ignored."
  def update_changeset(endpoint, attrs) do
    endpoint |> cast(attrs, @editable) |> validate_settings()
  end

  @doc false
  def enabled_changeset(endpoint, enabled), do: change(endpoint, enabled: enabled)

  defp validate_name(changeset) do
    changeset
    |> validate_format(:name, @name_format)
    |> unique_constraint(:name)
  end

  defp validate_settings(changeset) do
    changeset
    |> validate_change(:mcp_prefixes, fn :mcp_prefixes, prefixes ->
      cond do
        Enum.any?(prefixes, &(&1 in @forbidden_prefixes)) ->
          [mcp_prefixes: "must not include #{Enum.join(@forbidden_prefixes, ", ")}"]

        Enum.any?(prefixes, &(not Regex.match?(@prefix_format, &1))) ->
          [mcp_prefixes: "contains an invalid prefix"]

        true ->
          []
      end
    end)
    |> update_change(:mcp_prefixes, &Enum.uniq/1)
    |> update_change(:models, &Enum.uniq/1)
  end
end
