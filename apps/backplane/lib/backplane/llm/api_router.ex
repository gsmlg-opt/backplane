defmodule Backplane.LLM.ApiRouter do
  @moduledoc """
  REST API router for LLM provider and alias CRUD.

  Endpoints:
    GET    /providers           - List active providers (masked keys, preloaded aliases)
    POST   /providers           - Create provider
    GET    /providers/:id       - Get single provider
    PATCH  /providers/:id       - Update provider
    DELETE /providers/:id       - Soft delete provider
    GET    /aliases             - List all aliases
    POST   /aliases             - Create alias
    DELETE /aliases/:id         - Delete alias
  """

  use Plug.Router

  alias Backplane.LLM.{ModelAlias, Provider}

  plug(Plug.Parsers,
    parsers: [:json],
    pass: ["application/json"],
    json_decoder: Jason
  )

  plug(:match)
  plug(:dispatch)

  # ── Providers ────────────────────────────────────────────────────────────────

  get "/providers" do
    providers = Provider.list()
    json(conn, 200, Enum.map(providers, &serialize_provider/1))
  end

  post "/providers" do
    params = conn.body_params

    attrs =
      params
      |> maybe_convert_api_type()

    case Provider.create(attrs) do
      {:ok, provider} ->
        json(conn, 201, serialize_provider(provider))

      {:error, changeset} ->
        json(conn, 422, %{errors: format_errors(changeset)})
    end
  end

  get "/providers/:id" do
    case Provider.get(id) do
      nil -> json(conn, 404, %{error: "not found"})
      provider -> json(conn, 200, serialize_provider(provider))
    end
  end

  patch "/providers/:id" do
    case Provider.get(id) do
      nil ->
        json(conn, 404, %{error: "not found"})

      provider ->
        attrs = conn.body_params |> maybe_convert_api_type()

        case Provider.update(provider, attrs) do
          {:ok, updated} -> json(conn, 200, serialize_provider(updated))
          {:error, changeset} -> json(conn, 422, %{errors: format_errors(changeset)})
        end
    end
  end

  delete "/providers/:id" do
    case Provider.get(id) do
      nil ->
        json(conn, 404, %{error: "not found"})

      provider ->
        case Provider.soft_delete(provider) do
          {:ok, _deleted} -> json(conn, 200, %{ok: true})
          {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
        end
    end
  end

  # ── Aliases ──────────────────────────────────────────────────────────────────

  get "/aliases" do
    aliases = ModelAlias.list()
    json(conn, 200, Enum.map(aliases, &serialize_alias/1))
  end

  post "/aliases" do
    case ModelAlias.create(conn.body_params) do
      {:ok, model_alias} ->
        json(conn, 201, serialize_alias(model_alias))

      {:error, changeset} ->
        json(conn, 422, %{errors: format_errors(changeset)})
    end
  end

  delete "/aliases/:id" do
    case ModelAlias.get(id) do
      nil ->
        json(conn, 404, %{error: "not found"})

      model_alias ->
        case ModelAlias.delete(model_alias) do
          {:ok, _} -> json(conn, 200, %{ok: true})
          {:error, reason} -> json(conn, 500, %{error: inspect(reason)})
        end
    end
  end

  match _ do
    json(conn, 404, %{error: "not found"})
  end

  # ── Serialization ─────────────────────────────────────────────────────────────

  defp serialize_provider(%Provider{} = p) do
    %{
      id: p.id,
      name: p.name,
      api_type: to_string(p.api_type),
      api_url: p.api_url,
      api_key_hint: Provider.api_key_hint(p),
      credential: p.credential,
      models: p.models,
      rpm_limit: p.rpm_limit,
      default_headers: p.default_headers,
      enabled: p.enabled,
      aliases: serialize_aliases_list(p.aliases),
      inserted_at: p.inserted_at,
      updated_at: p.updated_at
    }
  end

  defp serialize_aliases_list(%Ecto.Association.NotLoaded{}), do: []

  defp serialize_aliases_list(aliases) when is_list(aliases),
    do: Enum.map(aliases, &serialize_alias_brief/1)

  defp serialize_alias(%ModelAlias{} = a) do
    %{
      id: a.id,
      alias: a.alias,
      model: a.model,
      provider_id: a.provider_id
    }
  end

  defp serialize_alias_brief(%ModelAlias{} = a) do
    %{
      id: a.id,
      alias: a.alias,
      model: a.model,
      provider_id: a.provider_id
    }
  end

  # ── Helpers ──────────────────────────────────────────────────────────────────

  defp json(conn, status, body) do
    conn
    |> Plug.Conn.put_resp_content_type("application/json")
    |> Plug.Conn.send_resp(status, Jason.encode!(body))
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end

  defp maybe_convert_api_type(%{"api_type" => api_type_str} = params)
       when is_binary(api_type_str) do
    atom =
      try do
        String.to_existing_atom(api_type_str)
      rescue
        ArgumentError -> api_type_str
      end

    Map.put(params, "api_type", atom)
  end

  defp maybe_convert_api_type(params), do: params
end
