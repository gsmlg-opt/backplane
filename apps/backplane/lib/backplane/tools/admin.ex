defmodule Backplane.Tools.Admin do
  @moduledoc """
  Native MCP tools for client management.

  These tools are scoped to `admin::*` — only clients with `"admin::*"` or `"*"`
  scope can call them (enforced by the scope guard in McpHandler).
  """

  @behaviour Backplane.Tools.ToolModule

  alias Backplane.Clients

  @impl true
  def tools do
    [
      %{
        name: "admin::list-clients",
        description: "List all registered MCP clients with their scopes and status",
        input_schema: %{
          "type" => "object",
          "properties" => %{}
        },
        module: __MODULE__,
        handler: :list_clients
      },
      %{
        name: "admin::upsert-client",
        description:
          "Create or update an MCP client. On create, token is required. On update (name exists), token is optional (omit to keep existing).",
        input_schema: %{
          "type" => "object",
          "properties" => %{
            "name" => %{
              "type" => "string",
              "description" => "Client identifier (unique)"
            },
            "token" => %{
              "type" => "string",
              "description" => "Bearer token (required on create, optional on update)"
            },
            "scopes" => %{
              "type" => "array",
              "items" => %{"type" => "string"},
              "description" =>
                "Tool scope allowlist. Examples: [\"*\"], [\"docs::*\", \"git::*\"], [\"docs::query-docs\"]"
            },
            "active" => %{
              "type" => "boolean",
              "description" => "Whether the client is active (default true)"
            }
          },
          "required" => ["name", "scopes"]
        },
        module: __MODULE__,
        handler: :upsert_client
      }
    ]
  end

  @impl true
  def call(%{"_handler" => "list_clients"}) do
    clients =
      Clients.list_clients()
      |> Enum.map(fn client ->
        %{
          id: client.id,
          name: client.name,
          scopes: client.scopes,
          active: client.active,
          last_seen_at: client.last_seen_at && DateTime.to_iso8601(client.last_seen_at)
        }
      end)

    {:ok, %{clients: clients}}
  end

  def call(%{"_handler" => "upsert_client"} = args) do
    name = args["name"]
    scopes = args["scopes"]
    token = args["token"]
    active = Map.get(args, "active", true)

    case Clients.get_client_by_name(name) do
      nil ->
        unless token do
          {:error, "Token is required when creating a new client"}
        else
          attrs = %{
            "name" => name,
            "token" => token,
            "scopes" => scopes,
            "active" => active
          }

          case Clients.create_client(attrs) do
            {:ok, client} -> {:ok, format_client(client)}
            {:error, changeset} -> {:error, format_errors(changeset)}
          end
        end

      existing ->
        attrs =
          %{"scopes" => scopes, "active" => active}
          |> then(fn a -> if token, do: Map.put(a, "token", token), else: a end)

        case Clients.update_client(existing, attrs) do
          {:ok, client} -> {:ok, format_client(client)}
          {:error, changeset} -> {:error, format_errors(changeset)}
        end
    end
  end

  defp format_client(client) do
    %{
      id: client.id,
      name: client.name,
      scopes: client.scopes,
      active: client.active
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, errors} -> "#{field}: #{Enum.join(errors, ", ")}" end)
  end
end
