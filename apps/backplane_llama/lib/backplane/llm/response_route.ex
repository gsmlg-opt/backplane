defmodule Backplane.LLM.ResponseRoute do
  @moduledoc """
  Durable owner-scoped routing for explicitly enabled Responses requests.

  Admission is persisted before submission; the upstream ID is bound before it
  can be forwarded. This index does not contain prompts, output, event cursors,
  plaintext credentials, or snapshots of request/response headers. Configuration
  and encrypted-credential fingerprints make subsequent changes fail closed.
  """

  use Ecto.Schema
  import Ecto.Changeset
  import Ecto.Query

  alias Backplane.LLM.{Provider, ProviderApi, ResponseCapability}
  alias Backplane.Repo
  alias Backplane.Settings.Credential

  @primary_key {:id, :binary_id, autogenerate: true}
  @timestamps_opts [type: :utc_datetime_usec]
  @terminal ~w(completed failed cancelled incomplete deleted)
  @statuses ~w(submitting submitted uncertain queued in_progress completed failed cancelled incomplete deleted)

  schema "llm_response_routes" do
    field(:owner_hash, :string)
    field(:response_id, :string)
    field(:provider_id, :binary_id)
    field(:provider_api_id, :binary_id)
    field(:api_target, :string)
    field(:credential_id, :binary_id)
    field(:credential_name, :string)
    field(:context_hash, :string)
    field(:status, :string, default: "submitting")
    field(:expires_at, :utc_datetime_usec)
    timestamps()
  end

  @doc "Persist an admission before sending a creation request upstream."
  def admit(conn, %Provider{} = provider, %ProviderApi{} = api) do
    with_store(fn ->
      with {:ok, owner_hash} <- owner_hash(conn),
           :ok <- ResponseCapability.validate(provider, api),
           {:ok, credential} <- credential(provider),
           :ok <- current_context(provider, api, credential) do
        %__MODULE__{}
        |> change(%{
          owner_hash: owner_hash,
          provider_id: provider.id,
          provider_api_id: api.id,
          api_target: safe_api_target(api.base_url),
          credential_id: credential.id,
          credential_name: credential.name,
          context_hash: context_hash(provider, api, credential),
          expires_at: DateTime.add(DateTime.utc_now(), api.responses_route_ttl_seconds, :second)
        })
        |> Repo.insert()
        |> normalize_write()
      end
    end)
  end

  @doc "Bind an upstream ID atomically; a collision never overwrites another route."
  def bind(%__MODULE__{} = route, response_id, status) do
    if valid_response_id?(response_id) do
      with_store(fn ->
        Repo.transaction(fn ->
          current = Repo.one(from(r in __MODULE__, where: r.id == ^route.id, lock: "FOR UPDATE"))

          cond do
            is_nil(current) -> Repo.rollback(:response_not_found)
            expired?(current) -> Repo.rollback(:response_expired)
            current.response_id not in [nil, response_id] -> Repo.rollback(:response_id_conflict)
            true -> bind_current(current, response_id, status)
          end
        end)
        |> case do
          {:ok, :ok} -> :ok
          {:error, reason} -> {:error, reason}
        end
      end)
    else
      {:error, :invalid_response_id}
    end
  end

  @doc "Resolve only an authenticated owner's original, unchanged provider context."
  def lookup(conn, response_id) do
    with_store(fn ->
      with {:ok, owner_hash} <- owner_hash(conn),
           true <- valid_response_id?(response_id),
           %__MODULE__{} = route <-
             Repo.get_by(__MODULE__, owner_hash: owner_hash, response_id: response_id),
           false <- route.status == "deleted",
           :ok <- check_expiry(route),
           {:ok, provider, api} <- routed_context(route) do
        {:ok, route, provider, api}
      else
        {:error, :response_expired} = error -> error
        {:error, :responses_identity_required} = error -> error
        {:error, _reason} = error -> error
        nil -> {:error, :response_not_found}
        false -> {:error, :response_not_found}
        true -> {:error, :response_not_found}
      end
    end)
  end

  @doc "Recheck the admitted context immediately before dispatch with resolved credentials."
  def verify(%__MODULE__{} = route) do
    with_store(fn ->
      with :ok <- check_expiry(route),
           {:ok, _provider, _api} <- routed_context(route) do
        :ok
      end
    end)
  end

  @doc "Return the exact encrypted credential snapshot validated against the durable route."
  def credential_snapshot(%__MODULE__{} = route) do
    with_store(fn ->
      with :ok <- check_expiry(route),
           {:ok, _provider, _api, credential} <- routed_snapshot(route) do
        {:ok, credential}
      end
    end)
  end

  @doc "Record observed state without regressing a terminal response."
  def mark(%__MODULE__{} = route, status) when status in @statuses do
    with_store(fn ->
      query = from(r in __MODULE__, where: r.id == ^route.id)

      query =
        if status == "deleted", do: query, else: where(query, [r], r.status not in ^@terminal)

      query
      |> Repo.update_all(set: [status: status, updated_at: DateTime.utc_now()])

      :ok
    end)
  end

  def mark(%__MODULE__{}, _status), do: :ok

  @doc "Submission may have reached the upstream. It must never be automatically replayed."
  def uncertain(%__MODULE__{} = route) do
    with_store(fn ->
      from(r in __MODULE__,
        where: r.id == ^route.id and is_nil(r.response_id) and r.status == "submitting"
      )
      |> Repo.update_all(set: [status: "uncertain", updated_at: DateTime.utc_now()])

      :ok
    end)
  end

  def valid_response_id?(id) when is_binary(id),
    do: Regex.match?(~r/\A[A-Za-z0-9_-]{1,255}\z/, id)

  def valid_response_id?(_id), do: false

  defp bind_current(current, response_id, status) do
    attrs = %{response_id: response_id}

    attrs =
      if current.status in @terminal,
        do: attrs,
        else: Map.put(attrs, :status, safe_status(status))

    current
    |> change(attrs)
    |> unique_constraint([:owner_hash, :response_id])
    |> unique_constraint([:provider_api_id, :response_id])
    |> Repo.update()
    |> case do
      {:ok, _route} -> :ok
      {:error, _changeset} -> Repo.rollback(:response_id_conflict)
    end
  end

  defp safe_status(status) when status in @statuses, do: status
  defp safe_status(_status), do: "in_progress"

  defp owner_hash(%Plug.Conn{assigns: %{resource_auth: auth}}) do
    case auth do
      %{kind: :client_token, client_id: client} when is_binary(client) and client != "" ->
        {:ok, digest({:client_token, client, Map.get(auth, :principal_metadata, %{})})}

      %{kind: :oauth, client_id: client, subject: subject}
      when is_binary(client) and client != "" and is_binary(subject) and subject != "" ->
        {:ok, digest({:oauth, client, subject, Map.get(auth, :principal_metadata, %{})})}

      _ ->
        {:error, :responses_identity_required}
    end
  end

  defp owner_hash(_conn), do: {:error, :responses_identity_required}

  defp credential(provider) do
    case Repo.get_by(Credential, name: provider.credential) do
      nil -> {:error, :response_route_changed}
      credential -> {:ok, credential}
    end
  end

  defp current_context(provider, api, credential) do
    with %Provider{} = current_provider <- Provider.get(provider.id),
         %ProviderApi{} = current_api <- ProviderApi.get(api.id),
         true <- current_api.provider_id == current_provider.id,
         :ok <- ResponseCapability.validate(current_provider, current_api),
         true <-
           context_hash(provider, api, credential) ==
             context_hash(current_provider, current_api, credential) do
      :ok
    else
      _ -> {:error, :response_route_changed}
    end
  end

  defp routed_context(route) do
    with {:ok, provider, api, _credential} <- routed_snapshot(route) do
      {:ok, provider, api}
    end
  end

  defp routed_snapshot(route) do
    with %Provider{} = provider <- Provider.get(route.provider_id),
         %ProviderApi{} = api <- ProviderApi.get(route.provider_api_id),
         {:ok, credential} <- credential(provider),
         :ok <- ResponseCapability.validate(provider, api),
         true <- api.provider_id == provider.id,
         true <- route.context_hash == context_hash(provider, api, credential) do
      {:ok, provider, api, credential}
    else
      _ -> {:error, :response_route_changed}
    end
  end

  defp context_hash(provider, api, credential) do
    digest({
      provider.id,
      provider.credential,
      provider.preset_key,
      provider.default_headers,
      api.id,
      api.provider_id,
      api.base_url,
      api.api_surface,
      api.native_protocols,
      api.default_headers,
      api.backend_config,
      credential.id,
      credential.name,
      credential.kind,
      credential.encrypted_value,
      credential.metadata
    })
  end

  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp safe_api_target(base_url) do
    base_url
    |> URI.parse()
    |> Map.merge(%{userinfo: nil, query: nil, fragment: nil})
    |> URI.to_string()
  end

  defp expired?(route), do: DateTime.compare(route.expires_at, DateTime.utc_now()) != :gt
  defp check_expiry(route), do: if(expired?(route), do: {:error, :response_expired}, else: :ok)
  defp normalize_write({:ok, route}), do: {:ok, route}
  defp normalize_write({:error, _changeset}), do: {:error, :responses_index_unavailable}

  defp with_store(fun) do
    fun.()
  rescue
    _error in [
      DBConnection.ConnectionError,
      DBConnection.OwnershipError,
      Ecto.ConstraintError,
      Postgrex.Error
    ] ->
      {:error, :responses_index_unavailable}
  catch
    :exit, _reason -> {:error, :responses_index_unavailable}
  end
end
