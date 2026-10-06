defmodule Backplane.Audio.RouteParser do
  @moduledoc false

  @behaviour Plug

  alias Backplane.Audio.{AccessLifecycle, Config, Error}
  alias Backplane.Audio.Media.Session
  alias Backplane.Transport.CacheBodyReader

  @conversation_parser Plug.Parsers.init(
                         parsers: [:json],
                         pass: ["application/json"],
                         json_decoder: Jason,
                         length: 50_000_000,
                         body_reader: {CacheBodyReader, :read_body, []}
                       )

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%Plug.Conn{method: "POST", request_path: "/v1/audio/speech"} = conn, _opts) do
    conn = Plug.Conn.put_private(conn, :audio_deadline, deadline())

    with :ok <- content_type(conn, "application/json"),
         :ok <- content_length(conn, Config.policy()["speech_json_bytes"]) do
      admitted(
        conn,
        :speech,
        Config.policy(),
        &parse_speech(&1, Config.policy()["speech_json_bytes"])
      )
    else
      {:error, error} -> parser_error(conn, error) |> Plug.Conn.halt()
    end
  end

  def call(%Plug.Conn{method: "POST", request_path: "/v1/audio/transcriptions"} = conn, _opts) do
    conn = Plug.Conn.put_private(conn, :audio_deadline, deadline())
    policy = Config.policy()
    limit = policy["upload_bytes"] + policy["multipart_overhead_bytes"]

    with :ok <- content_type(conn, "multipart/form-data"),
         :ok <- content_length(conn, limit) do
      admitted(conn, :transcription, policy, fn conn ->
        case read_parts(conn, policy, %{}, 0, 0) do
          {:ok, params, parsed_conn} ->
            %{parsed_conn | body_params: params, params: params}

          {:error, error, failed_conn} ->
            parser_error(failed_conn, error) |> Plug.Conn.halt()
        end
      end)
    else
      {:error, error} -> parser_error(conn, error) |> Plug.Conn.halt()
    end
  end

  def call(conn, _opts), do: Plug.Parsers.call(conn, @conversation_parser)

  defp deadline, do: System.monotonic_time(:millisecond) + Config.policy()["request_timeout_ms"]

  defp admitted(conn, operation, policy, parse) do
    queued_at = System.monotonic_time(:millisecond)

    case Session.start(self(), policy) do
      {:ok, session} ->
        with :ok <- if(operation == :transcription, do: Session.admit_upload(session), else: :ok),
             {:ok, observer} <-
               AccessLifecycle.start(
                 self(),
                 conn,
                 if(operation == :speech, do: "audio.speech", else: "audio.transcriptions"),
                 deadline_at_ms: conn.private.audio_deadline
               ) do
          :ok = Session.observe(session, observer)

          AccessLifecycle.update(observer, %{
            queue_ms: System.monotonic_time(:millisecond) - queued_at
          })

          conn =
            conn
            |> Plug.Conn.put_private(:audio_session, session)
            |> Plug.Conn.put_private(:audio_observer, observer)

          try do
            parsed = parse.(conn)
            if parsed.halted, do: Session.release(session)
            parsed
          rescue
            error ->
              AccessLifecycle.finish(observer, :error, nil, "audio_parser_failed")
              Session.release(session)
              reraise error, __STACKTRACE__
          end
        else
          error ->
            Session.release(session)

            failure =
              case error do
                {:error, %Error{} = failure} -> failure
                _ -> Error.new(503, "Audio observation unavailable", nil, "audio_unavailable")
              end

            parser_error(conn, failure) |> Plug.Conn.halt()
        end

      {:error, error} ->
        parser_error(conn, error) |> Plug.Conn.halt()
    end
  end

  defp parser_error(conn, error) do
    sent = Error.send(conn, error)
    AccessLifecycle.finish_error(conn.private[:audio_observer], error)
    sent
  end

  defp parse_speech(conn, limit) do
    case Plug.Conn.read_body(conn,
           length: limit + 1,
           read_length: 16_384,
           read_timeout: read_timeout(conn)
         ) do
      {:ok, body, conn} when byte_size(body) <= limit ->
        AccessLifecycle.update(conn.private[:audio_observer], %{request_bytes: byte_size(body)})

        case Jason.decode(body, objects: :ordered_objects) do
          {:ok, %Jason.OrderedObject{values: values}} ->
            names = Enum.map(values, &elem(&1, 0))

            if length(names) == length(Enum.uniq(names)) do
              params = Map.new(values)
              %{conn | body_params: params, params: params}
            else
              parser_error(
                conn,
                Error.new(400, "Duplicate JSON field", nil, "duplicate_parameter")
              )
              |> Plug.Conn.halt()
            end

          {:ok, _} ->
            parser_error(conn, Error.new(400, "Expected a JSON object", nil, "invalid_request"))
            |> Plug.Conn.halt()

          {:error, _} ->
            parser_error(conn, Error.new(400, "Malformed JSON", nil, "invalid_json"))
            |> Plug.Conn.halt()
        end

      {status, body, conn} when status in [:more, :ok] ->
        AccessLifecycle.update(conn.private[:audio_observer], %{request_bytes: byte_size(body)})

        parser_error(conn, Error.new(413, "Request body too large", nil, "request_too_large"))
        |> Plug.Conn.halt()

      {:error, _reason} ->
        parser_error(conn, timeout_error())
        |> Plug.Conn.halt()
    end
  end

  defp read_parts(conn, policy, params, overhead, count) when count <= 16 do
    result =
      if expired?(conn),
        do: {:error, timeout_error(), conn},
        else: do_read_parts(conn, policy, params, overhead, count)

    if match?({:error, _, _}, result), do: cleanup_upload(params)
    result
  rescue
    _ ->
      cleanup_upload(params)
      {:error, Error.new(400, "Malformed multipart body", nil, "malformed_request"), conn}
  end

  defp read_parts(conn, _policy, params, _overhead, _count) do
    cleanup_upload(params)
    {:error, Error.new(413, "Too many multipart fields", nil, "request_too_large"), conn}
  end

  defp do_read_parts(conn, policy, params, overhead, count) do
    remaining = policy["multipart_overhead_bytes"] - overhead

    case Plug.Conn.read_part_headers(conn,
           length: max(remaining, 1),
           read_length: 16_384,
           read_timeout: read_timeout(conn)
         ) do
      {:done, conn} ->
        if match?(%Plug.Upload{}, params["file"]),
          do: {:ok, params, conn},
          else:
            {:error, Error.new(400, "File is required", "file", "missing_required_parameter"),
             conn}

      {:error, :too_large, conn} ->
        {:error, Error.new(413, "Multipart overhead too large", nil, "request_too_large"), conn}

      {:ok, headers, conn} ->
        header_bytes =
          Enum.reduce(headers, 0, fn {k, v}, sum -> sum + byte_size(k) + byte_size(v) end)

        overhead = overhead + header_bytes + 256

        with :ok <- check_overhead(overhead, policy),
             {:ok, name, filename} <- part_identity(headers),
             :ok <- check_part_name(name, filename, params),
             {:ok, value, conn, overhead} <-
               read_part(conn, name, filename, headers, policy, overhead) do
          read_parts(conn, policy, Map.put(params, name, value), overhead, count + 1)
        else
          {:error, error} -> {:error, error, conn}
          {:error, error, failed_conn} -> {:error, error, failed_conn}
        end
    end
  end

  defp part_identity(headers) do
    case List.keyfind(headers, "content-disposition", 0) do
      {_, disposition} ->
        [kind | rest] = String.split(disposition, ";")
        fields = Plug.Conn.Utils.params(Enum.join(rest, ";"))

        case fields["name"] do
          name when is_binary(name) and kind == "form-data" ->
            {:ok, name, fields["filename"]}

          _ ->
            {:error, Error.new(400, "Multipart field name is missing", nil, "malformed_request")}
        end

      nil ->
        {:error, Error.new(400, "Multipart disposition is missing", nil, "malformed_request")}
    end
  end

  defp check_part_name(name, filename, params) do
    cond do
      name not in ~w(model file response_format language stream prompt temperature timestamp_granularities timestamp_granularities[] speaker chunking_strategy include logprobs) ->
        {:error, Error.new(400, "Unsupported multipart field", name, "unsupported_parameter")}

      Map.has_key?(params, name) ->
        {:error, Error.new(400, "Duplicate multipart field", name, "duplicate_parameter")}

      name == "file" and not is_binary(filename) ->
        {:error, Error.new(400, "File upload is required", "file", "invalid_parameter")}

      name != "file" and is_binary(filename) ->
        {:error, Error.new(400, "Unexpected file upload", name, "invalid_parameter")}

      true ->
        :ok
    end
  end

  defp read_part(conn, "file", filename, headers, policy, overhead) do
    case allocate_upload() do
      {:ok, path} ->
        read_upload(conn, path, filename, headers, policy, overhead)

      :error ->
        {:error, Error.new(503, "Upload storage unavailable", "file", "upload_unavailable"), conn}
    end
  end

  defp read_part(conn, _name, _filename, _headers, policy, overhead) do
    case read_part_chunks(conn, [], overhead, policy["multipart_overhead_bytes"]) do
      {:ok, conn, chunks, bytes} -> {:ok, IO.iodata_to_binary(Enum.reverse(chunks)), conn, bytes}
      {:error, error, conn} -> {:error, error, conn}
    end
  end

  defp allocate_upload do
    case Plug.Upload.random_file("audio") do
      {:ok, path} -> {:ok, path}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp read_upload(conn, path, filename, headers, policy, overhead) do
    content_type =
      case List.keyfind(headers, "content-type", 0) do
        {_, value} -> value
        nil -> nil
      end

    case File.open(path, [:write, :binary, :raw]) do
      {:ok, io} ->
        result =
          try do
            read_part_chunks(conn, io, 0, policy["upload_bytes"])
          rescue
            _ ->
              {:error, Error.new(400, "Malformed multipart body", nil, "malformed_request"), conn}
          after
            File.close(io)
          end

        case result do
          {:ok, conn} ->
            {:ok, %Plug.Upload{path: path, filename: filename, content_type: content_type}, conn,
             overhead}

          {:error, error, conn} ->
            Plug.Upload.delete(path)
            {:error, error, conn}
        end

      {:error, _} ->
        Plug.Upload.delete(path)
        {:error, Error.new(503, "Upload storage unavailable", "file", "upload_unavailable"), conn}
    end
  end

  defp read_part_chunks(conn, io, bytes, limit) when not is_list(io) do
    if expired?(conn),
      do: {:error, timeout_error(), conn},
      else: do_read_part_chunks(conn, io, bytes, limit)
  end

  defp read_part_chunks(conn, chunks, bytes, limit) when is_list(chunks) do
    if expired?(conn),
      do: {:error, timeout_error(), conn},
      else: do_read_part_chunks(conn, chunks, bytes, limit)
  end

  defp do_read_part_chunks(conn, io, bytes, limit) when not is_list(io) do
    case Plug.Conn.read_part_body(conn,
           length: 16_384,
           read_length: 16_384,
           read_timeout: read_timeout(conn)
         ) do
      {status, chunk, conn} when status in [:ok, :more] ->
        bytes = bytes + byte_size(chunk)
        AccessLifecycle.update(conn.private[:audio_observer], %{request_bytes: bytes})

        cond do
          bytes > limit ->
            {:error, Error.new(413, "File exceeds upload limit", "file", "file_too_large"), conn}

          true ->
            case :file.write(io, chunk) do
              :ok ->
                if status == :ok, do: {:ok, conn}, else: read_part_chunks(conn, io, bytes, limit)

              {:error, _} ->
                {:error,
                 Error.new(503, "Upload storage unavailable", "file", "upload_unavailable"), conn}
            end
        end
    end
  end

  defp do_read_part_chunks(conn, chunks, bytes, limit) when is_list(chunks) do
    case Plug.Conn.read_part_body(conn,
           length: 16_384,
           read_length: 16_384,
           read_timeout: read_timeout(conn)
         ) do
      {status, chunk, conn} when status in [:ok, :more] ->
        bytes = bytes + byte_size(chunk)

        cond do
          bytes > limit ->
            {:error, Error.new(413, "Multipart overhead too large", nil, "request_too_large"),
             conn}

          status == :ok ->
            {:ok, conn, [chunk | chunks], bytes}

          true ->
            read_part_chunks(conn, [chunk | chunks], bytes, limit)
        end
    end
  end

  defp check_overhead(value, policy) do
    if value <= policy["multipart_overhead_bytes"],
      do: :ok,
      else: {:error, Error.new(413, "Multipart overhead too large", nil, "request_too_large")}
  end

  defp cleanup_upload(%{"file" => %Plug.Upload{} = upload}), do: Plug.Upload.delete(upload)
  defp cleanup_upload(_), do: :ok

  defp content_type(conn, expected) do
    valid? =
      case Plug.Conn.get_req_header(conn, "content-type") do
        [value] ->
          case Plug.Conn.Utils.content_type(value) do
            {:ok, type, subtype, params} ->
              type <> "/" <> subtype == expected and
                (expected != "multipart/form-data" or valid_boundary?(params["boundary"]))

            _ ->
              false
          end

        _ ->
          false
      end

    if valid?,
      do: :ok,
      else:
        {:error,
         Error.new(415, "Unsupported request content type", nil, "unsupported_media_type")}
  end

  defp valid_boundary?(value) when is_binary(value) do
    byte_size(value) in 1..70 and
      Regex.match?(~r/^[0-9A-Za-z'()+_,.\/:=? -]*[0-9A-Za-z'()+_,.\/:=?-]$/, value)
  end

  defp valid_boundary?(_), do: false

  defp content_length(conn, limit) do
    case Plug.Conn.get_req_header(conn, "content-length") do
      [value] ->
        case Integer.parse(value) do
          {size, ""} when size > limit ->
            {:error, Error.new(413, "Request body too large", nil, "request_too_large")}

          _ ->
            :ok
        end

      _ ->
        :ok
    end
  end

  defp expired?(conn), do: remaining(conn) <= 0

  defp remaining(conn),
    do: max(conn.private.audio_deadline - System.monotonic_time(:millisecond), 0)

  defp read_timeout(conn), do: max(min(remaining(conn), 5_000), 1)

  defp timeout_error,
    do: Error.new(504, "Audio request timed out", nil, "audio_timeout", "api_error")
end
