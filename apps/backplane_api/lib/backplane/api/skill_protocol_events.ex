defmodule Backplane.Api.SkillProtocolEvents do
  @moduledoc "Authenticated Skill Protocol directory notification upgrade."

  @behaviour Plug

  import Plug.Conn

  alias Backplane.Api.SkillProtocolEvents.Socket
  alias Backplane.Auth.ResourceAuthPlug
  alias Relayixir.Proxy.WebSocket.Adapter

  @credential_headers ~w(authorization x-api-key api-key x-goog-api-key)

  defmodule AuthRequest do
    @moduledoc false
    @derive {Inspect, except: [:conn]}
    defstruct [:conn]
  end

  @impl true
  def init(action), do: action

  @impl true
  def call(conn, :capture) do
    if conn.request_path == "/skill-protocol/v1/events" do
      put_private(
        conn,
        :skill_protocol_auth_headers,
        Enum.filter(conn.req_headers, fn {name, _} -> name in @credential_headers end)
      )
    else
      conn
    end
  end

  def call(conn, :upgrade) do
    conn = fetch_query_params(conn)
    generation = conn.query_params["generation"]

    cond do
      not Application.get_env(:backplane_skills, :skill_protocol_v1_enabled, true) ->
        send_resp(conn, 404, "not found")

      Map.keys(conn.query_params) -- ["generation"] != [] or
          not (is_nil(generation) or (is_binary(generation) and byte_size(generation) <= 256)) ->
        send_resp(conn, 400, "invalid generation")

      Adapter.validate_upgrade(conn) != :ok ->
        send_resp(conn, 400, "WebSocket upgrade required")

      true ->
        auth_conn = %Plug.Conn{
          method: "GET",
          request_path: "/skill-protocol/v1/events",
          path_info: ["skill-protocol", "v1", "events"],
          scheme: conn.scheme,
          host: conn.host,
          port: conn.port,
          req_headers: Map.get(conn.private, :skill_protocol_auth_headers, conn.req_headers),
          adapter: {__MODULE__.AuthAdapter, nil}
        }

        Adapter.upgrade(
          conn,
          Socket,
          %{
            auth_conn: %AuthRequest{conn: auth_conn},
            generation: generation
          },
          timeout: 45_000,
          max_frame_size: 4 * 1024 * 1024,
          max_message_size: 4 * 1024 * 1024
        )
    end
  end

  @doc false
  def authorized?(%AuthRequest{conn: conn}) do
    opts =
      ResourceAuthPlug.init(
        resource: :skill_protocol,
        allow_client_bypass: ~w(GET HEAD),
        required_scope: {Backplane.Api.SkillProtocolAuthorization, :required_scope, []}
      )

    authenticated = ResourceAuthPlug.call(conn, opts)

    Application.get_env(:backplane_skills, :skill_protocol_v1_enabled, true) and
      not authenticated.halted and
      not Backplane.Api.SkillProtocolAuthorization.call(authenticated, []).halted
  rescue
    _ -> false
  catch
    :exit, _ -> false
  end

  defmodule AuthAdapter do
    @moduledoc false
    # Revalidation runs after upgrade. Authentication failures become WebSocket
    # closes, so their HTTP response is consumed without writing to the socket.
    def send_resp(payload, _status, _headers, body), do: {:ok, body, payload}
  end
end
