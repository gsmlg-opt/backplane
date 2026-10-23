defmodule Backplane.Api.PluginController do
  @moduledoc "Backplane registry APIs; Agent Plugins 1.0 specifies the package format."
  use Backplane.Api, :controller
  alias Backplane.Plugins

  def plugins(conn, _params),
    do:
      json(conn, %{
        data:
          Enum.map(
            Plugins.list_plugins(),
            &Map.take(&1, ~w(id identity publisher name source_id)a)
          )
      })

  def releases(conn, %{"id" => id}) do
    if Plugins.get_plugin(id) do
      json(conn, %{data: Enum.map(Plugins.list_releases(id), &release_json/1)})
    else
      error(conn, 404, "not_found")
    end
  end

  def catalog(conn, params) do
    if scalar?(params, ~w(channel)) do
      json(conn, Plugins.catalog(channel: params["channel"] || "stable"))
    else
      error(conn, 400, "invalid_request")
    end
  end

  def resolve(conn, %{"plugin_id" => id} = params) do
    if scalar?(params, ~w(plugin_id release_id channel)) and id != "" do
      respond(
        conn,
        Plugins.resolve(id, params["release_id"], channel: params["channel"] || "stable")
      )
    else
      error(conn, 400, "invalid_request")
    end
  end

  def resolve(conn, _params), do: error(conn, 400, "plugin_id_required")

  def artifact(conn, %{"digest" => digest}) do
    if Regex.match?(~r/\A[0-9a-f]{64}\z/, digest) do
      case Plugins.artifact_by_digest(digest) do
        {:ok, bytes} ->
          etag = ~s("#{digest}")
          conn = conn |> put_resp_header("etag", etag)

          if etag in get_req_header(conn, "if-none-match") do
            send_resp(conn, 304, "")
          else
            conn
            |> put_resp_content_type("application/gzip")
            |> put_resp_header("content-length", to_string(byte_size(bytes)))
            |> send_resp(200, bytes)
          end

        {:error, :not_found} ->
          error(conn, 404, "not_found")

        {:error, _} ->
          error(conn, 409, "integrity_mismatch")
      end
    else
      error(conn, 400, "invalid_digest")
    end
  end

  def import(conn, %{"archive_base64" => encoded} = params) when is_binary(encoded) do
    with true <- byte_size(encoded) <= 90_000_000,
         true <- optional_strings?(params, ~w(publisher identity)),
         {:ok, bytes} <- Base.decode64(encoded),
         {:ok, release} <- Plugins.import_archive(bytes, Map.take(params, ~w(publisher identity))) do
      json(conn |> put_status(201), release_json(release))
    else
      _ -> error(conn, 422, "invalid_plugin_package")
    end
  end

  def import(conn, _params), do: error(conn, 400, "archive_base64_required")

  def compose(conn, %{"manifest" => manifest, "skills" => selections} = params)
      when is_map(manifest) and is_list(selections) do
    with true <- optional_strings?(params, ~w(publisher identity)),
         true <- Enum.all?(selections, &valid_selection?/1),
         {:ok, files} <- composition_files(params),
         {:ok, release} <-
           Plugins.compose(manifest, selections, files, Map.take(params, ~w(publisher identity))) do
      json(conn |> put_status(201), release_json(release))
    else
      _ -> error(conn, 422, "invalid_composition")
    end
  end

  def compose(conn, _params), do: error(conn, 400, "invalid_composition")

  def publish(conn, %{"id" => id} = params) do
    if is_binary(params["channel"] || "stable") do
      case Plugins.publish_release(id, params["channel"] || "stable") do
        {:ok, release} -> json(conn, release_json(release))
        _ -> error(conn, 422, "publication_failed")
      end
    else
      error(conn, 400, "invalid_channel")
    end
  end

  def sources(conn, _params),
    do: json(conn, %{data: Enum.map(Plugins.list_sources(), &source_json/1)})

  def create_source(conn, params) do
    case Plugins.create_source(
           Map.take(
             params,
             ~w(name url ref path kind credential_name auto_publish enabled interval_seconds)
           )
         ) do
      {:ok, source} -> json(conn |> put_status(201), source_json(source))
      _ -> error(conn, 422, "invalid_source")
    end
  end

  def update_source(conn, %{"id" => id} = params) do
    case Plugins.get_source(id) do
      nil ->
        error(conn, 404, "not_found")

      source ->
        attrs =
          Map.take(
            params,
            ~w(name url ref path kind credential_name auto_publish enabled interval_seconds)
          )

        case Plugins.update_source(source, attrs) do
          {:ok, updated} -> json(conn, source_json(updated))
          _ -> error(conn, 422, "invalid_source")
        end
    end
  end

  def delete_source(conn, %{"id" => id}) do
    case Plugins.get_source(id) do
      nil ->
        error(conn, 404, "not_found")

      source ->
        case Plugins.delete_source(source) do
          {:ok, _} -> send_resp(conn, 204, "")
          _ -> error(conn, 422, "source_delete_failed")
        end
    end
  end

  def sync_source(conn, %{"id" => id}) do
    case Plugins.sync_source(id) do
      {:ok, result} ->
        json(conn, %{
          data: Enum.map(result.releases, &release_json/1),
          diagnostics: result.diagnostics
        })

      _ ->
        error(conn, 422, "source_sync_failed")
    end
  end

  def installations(conn, _params) do
    opts =
      case target(conn) do
        :operator -> []
        target -> [target: target]
      end

    json(conn, %{data: Enum.map(Plugins.list_installations(opts), &installation_json/1)})
  end

  def set_desired(
        conn,
        %{"target" => target, "plugin_id" => plugin_id, "release_id" => release_id} = params
      )
      when is_binary(target) and is_binary(plugin_id) and is_binary(release_id) do
    case Plugins.set_desired(target, plugin_id, release_id, Map.take(params, ~w(enabled))) do
      {:ok, installed} -> json(conn, installation_json(installed))
      _ -> error(conn, 422, "invalid_installation")
    end
  end

  def set_desired(conn, _params), do: error(conn, 400, "invalid_installation")

  def report(conn, %{"id" => id} = params) do
    installed = Plugins.get_installation(id)

    cond do
      is_nil(installed) ->
        error(conn, 404, "not_found")

      target(conn) not in [:operator, installed.target] ->
        error(conn, 403, "wrong_installation_target")

      true ->
        attrs = Map.take(params, ~w(actual_release_id status actual_enabled components))

        case Plugins.report_installation(id, attrs) do
          {:ok, updated} -> json(conn, installation_json(updated))
          _ -> error(conn, 422, "invalid_report")
        end
    end
  end

  defp target(%{assigns: %{resource_auth: %{kind: :open}}}), do: :operator
  defp target(%{assigns: %{resource_auth: %{client_id: id}}}), do: "client:" <> id

  defp scalar?(params, keys),
    do: Enum.all?(params, fn {key, value} -> key in keys and is_binary(value) end)

  defp optional_strings?(params, keys),
    do:
      Enum.all?(keys, fn key ->
        not Map.has_key?(params, key) or (is_binary(params[key]) and params[key] != "")
      end)

  defp valid_selection?(selection) when is_map(selection),
    do: Enum.all?(~w(skill_id revision name), &(is_binary(selection[&1]) and selection[&1] != ""))

  defp valid_selection?(_), do: false

  defp composition_files(params) do
    case Map.get(params, "files_base64", %{}) do
      encoded when is_map(encoded) ->
        Enum.reduce_while(encoded, {:ok, %{}}, fn
          {path, bytes}, {:ok, files} when is_binary(path) and is_binary(bytes) ->
            case Base.decode64(bytes) do
              {:ok, decoded} -> {:cont, {:ok, Map.put(files, path, decoded)}}
              _ -> {:halt, {:error, :invalid_file}}
            end

          _, _ ->
            {:halt, {:error, :invalid_file}}
        end)

      _ ->
        {:error, :invalid_files}
    end
  end

  defp respond(conn, {:ok, value}), do: json(conn, value)
  defp respond(conn, {:error, :not_found}), do: error(conn, 404, "not_found")
  defp error(conn, status, code), do: conn |> put_status(status) |> json(%{error: %{code: code}})

  defp release_json(release),
    do:
      Map.take(
        release,
        ~w(id plugin_id upstream_version artifact_digest source_commit source_path manifest diagnostics published_at)a
      )

  defp source_json(source),
    do:
      Map.take(
        source,
        ~w(id name url ref path kind auto_publish enabled interval_seconds status source_commit diagnostics last_attempt_at last_success_at)a
      )

  defp installation_json(installed),
    do:
      Map.take(
        installed,
        ~w(id target plugin_id desired_release_id actual_release_id enabled actual_enabled status components reported_at)a
      )
end
