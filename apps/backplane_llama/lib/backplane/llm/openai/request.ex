defmodule Backplane.LLM.OpenAI.Request do
  @moduledoc false
  import Plug.Conn

  @max_bytes 100_000_000
  def read(conn, limit \\ @max_bytes) do
    read_chunks(
      conn,
      [],
      0,
      min(limit, @max_bytes),
      System.monotonic_time(:millisecond) + 120_000
    )
  end

  defp read_chunks(conn, chunks, bytes, limit, deadline) do
    timeout = deadline - System.monotonic_time(:millisecond)

    result =
      if timeout > 0,
        do: read_body(conn, length: 65_536, read_length: 65_536, read_timeout: timeout),
        else: {:error, :timeout}

    case result do
      {status, body, conn} when status in [:ok, :more] and bytes + byte_size(body) > limit ->
        {:error, conn, :request_too_large}

      {:more, body, conn} ->
        read_chunks(conn, [body | chunks], bytes + byte_size(body), limit, deadline)

      {:ok, body, conn} ->
        body = IO.iodata_to_binary(Enum.reverse([body | chunks]))

        case parse(body, get_req_header(conn, "content-type")) do
          {:ok, request} -> {:ok, conn, request}
          {:error, code} -> {:error, conn, code}
        end

      {:error, _} ->
        {:error, conn, :invalid_request}
    end
  end

  def parse(body, [content_type]) do
    case Plug.Conn.Utils.media_type(content_type) do
      {:ok, "application", "json", _} ->
        case decode_json(body) do
          {:ok, params} when is_map(params) -> {:ok, %{type: :json, body: body, params: params}}
          _ -> {:error, :invalid_json}
        end

      {:ok, "multipart", "form-data", %{"boundary" => boundary}}
      when byte_size(boundary) in 1..70 ->
        multipart(body, boundary)

      {:ok, "application", "sdp", _} ->
        {:ok, %{type: :sdp, body: body}}

      _ ->
        {:error, :unsupported_media_type}
    end
  end

  def parse(_, _), do: {:error, :unsupported_media_type}

  def model(%{type: :json, params: params}, :realtime), do: nested_model(params)
  def model(%{type: :json, params: params}, _), do: model_value(params["model"])
  def model(%{type: :sdp}, _), do: {:ok, nil}

  def model(%{type: :multipart, parts: parts}, kind) do
    name = if kind == :realtime, do: "session", else: "model"

    case Enum.filter(parts, &(&1.name == name)) do
      [] ->
        {:ok, nil}

      [%{filename: nil, data: data}] when kind == :realtime ->
        case decode_json(data) do
          {:ok, params} when is_map(params) -> nested_model(params)
          _ -> {:error, :invalid_json}
        end

      [%{filename: nil, data: data}] ->
        model_value(data)

      _ ->
        {:error, :duplicate_model}
    end
  end

  def rewrite(%{type: :json} = request, kind, raw) do
    {:ok, current} = model(request, kind)

    if current == raw do
      request.body
    else
      params =
        if kind == :realtime,
          do: put_session_model(request.params, raw),
          else: Map.put(request.params, "model", raw)

      Jason.encode!(params)
    end
  end

  def rewrite(%{type: :sdp, body: body}, _, _), do: body

  def rewrite(%{type: :multipart} = request, kind, raw) do
    field = if kind == :realtime, do: "session", else: "model"
    {:ok, current} = model(request, kind)

    if current == raw do
      request.body
    else
      case Enum.find(request.parts, &(&1.name == field)) do
        nil ->
          data =
            if kind == :realtime, do: Jason.encode!(%{type: "realtime", model: raw}), else: raw

          ending = "--" <> request.boundary <> "--"

          addition =
            "--" <>
              request.boundary <>
              "\r\nContent-Disposition: form-data; name=\"#{field}\"\r\n\r\n" <>
              data <> "\r\n" <> ending

          :binary.replace(request.body, ending, addition)

        part ->
          data =
            if kind == :realtime,
              do: part.data |> Jason.decode!() |> put_session_model(raw) |> Jason.encode!(),
              else: raw

          prefix = "--" <> request.boundary <> "\r\n" <> part.header <> "\r\n\r\n"
          :binary.replace(request.body, prefix <> part.data <> "\r\n", prefix <> data <> "\r\n")
      end
    end
  end

  def audio_params(%{type: :json, params: params}), do: {:ok, params}

  def audio_params(%{type: :multipart, parts: parts}) do
    names = Enum.map(parts, & &1.name)

    if length(names) == length(Enum.uniq(names)) and
         Enum.all?(parts, &(is_nil(&1.filename) or &1.name == "file")) do
      build_audio_params(parts)
    else
      {:error, :duplicate_parameter}
    end
  end

  defp build_audio_params(parts) do
    Enum.reduce_while(parts, {:ok, %{}}, fn part, {:ok, params} ->
      cond do
        Map.has_key?(params, part.name) ->
          {:halt, {:error, :duplicate_parameter}}

        part.filename && part.name != "file" ->
          {:halt, {:error, :invalid_parameter}}

        part.name == "file" && is_nil(part.filename) ->
          {:halt, {:error, :invalid_parameter}}

        part.filename ->
          {:ok, path} = Plug.Upload.random_file("audio")

          case File.write(path, part.data) do
            :ok ->
              upload = %Plug.Upload{
                path: path,
                filename: part.filename,
                content_type: part.content_type
              }

              {:cont, {:ok, Map.put(params, part.name, upload)}}

            _ ->
              Plug.Upload.delete(path)
              {:halt, {:error, :upload_unavailable}}
          end

        true ->
          {:cont, {:ok, Map.put(params, part.name, part.data)}}
      end
    end)
  end

  defp decode_json(bytes) do
    with {:ok, ordered} <- Jason.decode(bytes, objects: :ordered_objects),
         :ok <- unique_keys(ordered) do
      Jason.decode(bytes)
    else
      _ -> {:error, :invalid_json}
    end
  end

  defp unique_keys(%Jason.OrderedObject{values: values}) do
    names = Enum.map(values, &elem(&1, 0))

    if length(names) == length(Enum.uniq(names)),
      do: unique_keys(Enum.map(values, &elem(&1, 1))),
      else: :error
  end

  defp unique_keys(values) when is_list(values) do
    if Enum.all?(values, &(unique_keys(&1) == :ok)), do: :ok, else: :error
  end

  defp unique_keys(_), do: :ok

  defp multipart(body, boundary) do
    prefix = "--" <> boundary <> "\r\n"
    ending = "\r\n--" <> boundary <> "--"

    with true <- String.starts_with?(body, prefix),
         {ending_at, _} <- :binary.match(body, ending),
         true <-
           binary_part(
             body,
             ending_at + byte_size(ending),
             byte_size(body) - ending_at - byte_size(ending)
           ) in ["", "\r\n"] do
      middle = binary_part(body, byte_size(prefix), ending_at - byte_size(prefix))
      sections = :binary.split(middle, "\r\n--" <> boundary <> "\r\n", [:global])

      if length(sections) <= 128 do
        Enum.reduce_while(sections, {:ok, []}, fn section, {:ok, parts} ->
          case parse_part(section) do
            {:ok, part} -> {:cont, {:ok, [part | parts]}}
            error -> {:halt, error}
          end
        end)
        |> case do
          {:ok, parts} ->
            {:ok, %{type: :multipart, body: body, boundary: boundary, parts: Enum.reverse(parts)}}

          error ->
            error
        end
      else
        {:error, :too_many_parts}
      end
    else
      _ -> {:error, :malformed_multipart}
    end
  end

  defp parse_part(section) do
    with [header, data] <- :binary.split(section, "\r\n\r\n"),
         true <- byte_size(header) <= 16_384,
         headers <- String.split(header, "\r\n"),
         disposition when is_binary(disposition) <- find_header(headers, "content-disposition"),
         ["form-data" | rest] <- String.split(disposition, ";"),
         params <- Plug.Conn.Utils.params(Enum.join(rest, ";")),
         name when is_binary(name) <- params["name"] do
      {:ok,
       %{
         header: header,
         data: data,
         name: name,
         filename: params["filename"],
         content_type: find_header(headers, "content-type")
       }}
    else
      _ -> {:error, :malformed_multipart}
    end
  end

  defp find_header(headers, name) do
    Enum.find_value(headers, fn header ->
      case String.split(header, ":", parts: 2) do
        [key, value] -> if String.downcase(key) == name, do: String.trim(value)
        _ -> nil
      end
    end)
  end

  defp model_value(nil), do: {:ok, nil}
  defp model_value(value) when is_binary(value) and byte_size(value) in 1..1024, do: {:ok, value}
  defp model_value(_), do: {:error, :invalid_model}

  defp nested_model(%{"session" => session}) when is_map(session),
    do: model_value(session["model"])

  defp nested_model(params), do: model_value(params["model"])

  defp put_session_model(%{"session" => session} = params, raw) when is_map(session),
    do: Map.put(params, "session", Map.put(session, "model", raw))

  defp put_session_model(params, raw), do: Map.put(params, "model", raw)
end
