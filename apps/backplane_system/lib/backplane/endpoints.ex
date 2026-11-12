defmodule Backplane.Endpoints do
  @moduledoc """
  Context for named endpoints and their access policy.
  """

  import Ecto.Query

  alias Backplane.Endpoints.{Cache, Endpoint}
  alias Backplane.Repo

  @type t :: Endpoint.t()

  @spec forbidden_prefixes() :: [String.t()]
  defdelegate forbidden_prefixes, to: Endpoint

  @spec list() :: [Endpoint.t()]
  def list, do: Endpoint |> order_by(:name) |> Repo.all()

  @spec get!(String.t()) :: Endpoint.t()
  def get!(id), do: Repo.get!(Endpoint, id)

  @spec get_by_name(String.t()) :: Endpoint.t() | nil
  def get_by_name(name) when is_binary(name) do
    if Endpoint.valid_name?(name),
      do: Cache.fetch(name, fn -> Repo.get_by(Endpoint, name: name) end)
  end

  @spec create(map()) :: {:ok, Endpoint.t()} | {:error, Ecto.Changeset.t()}
  def create(attrs) do
    %Endpoint{} |> Endpoint.create_changeset(attrs) |> Repo.insert() |> after_write()
  end

  @spec update(Endpoint.t(), map()) :: {:ok, Endpoint.t()} | {:error, Ecto.Changeset.t()}
  def update(%Endpoint{} = endpoint, attrs) do
    endpoint |> Endpoint.update_changeset(attrs) |> Repo.update() |> after_write()
  end

  @spec set_enabled(Endpoint.t(), boolean()) ::
          {:ok, Endpoint.t()} | {:error, Ecto.Changeset.t()}
  def set_enabled(%Endpoint{} = endpoint, enabled) when is_boolean(enabled) do
    endpoint |> Endpoint.enabled_changeset(enabled) |> Repo.update() |> after_write()
  end

  @spec delete(Endpoint.t()) :: {:ok, Endpoint.t()} | {:error, Ecto.Changeset.t()}
  def delete(%Endpoint{} = endpoint), do: endpoint |> Repo.delete() |> after_write()

  @doc "Return the endpoint when it exists, is enabled and has `feature` on."
  @spec active(String.t(), :mcp | :llm) :: {:ok, Endpoint.t()} | :error
  def active(name, feature) when feature in [:mcp, :llm] do
    case get_by_name(name) do
      %Endpoint{enabled: true} = e -> if feature_on?(e, feature), do: {:ok, e}, else: :error
      _ -> :error
    end
  end

  defp feature_on?(e, :mcp), do: e.mcp_enabled
  defp feature_on?(e, :llm), do: e.llm_enabled

  @spec client_allowed?(map(), :oauth | :client_token, String.t()) :: boolean()
  def client_allowed?(%{restrict_clients: false}, _kind, _id), do: true
  def client_allowed?(%{oauth_client_ids: ids}, :oauth, id), do: id in ids
  def client_allowed?(%{client_ids: ids}, :client_token, id), do: id in ids

  @doc """
  Intersect caller scopes with the endpoint's MCP prefixes. A prefix gets
  `prefix::*` when the caller holds `*` or `prefix::*`; otherwise the caller's
  `prefix::name` scopes are kept.
  """
  @spec restrict_tool_scopes(map(), [String.t()]) :: [String.t()]
  def restrict_tool_scopes(%{mcp_prefixes: prefixes}, caller_scopes) do
    prefixes
    |> Enum.flat_map(fn p ->
      if "*" in caller_scopes or "#{p}::*" in caller_scopes do
        ["#{p}::*"]
      else
        Enum.filter(caller_scopes, &String.starts_with?(&1, p <> "::"))
      end
    end)
    |> Enum.uniq()
  end

  @spec model_allowed?(map(), String.t()) :: boolean()
  def model_allowed?(%{models: models}, model), do: model in models

  @doc """
  Invalidate the cached endpoint `name`.

  Writes invalidate immediately, but when a write runs inside an outer
  `Repo.transaction`, readers may re-cache the pre-commit row; callers must
  call this again after the outermost commit.
  """
  @spec invalidate(String.t()) :: :ok
  defdelegate invalidate(name), to: Cache, as: :delete

  defp after_write({:ok, %Endpoint{name: name}} = result) do
    Cache.delete(name)
    result
  end

  defp after_write(result), do: result
end
