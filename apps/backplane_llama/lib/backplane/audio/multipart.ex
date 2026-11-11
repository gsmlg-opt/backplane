defmodule Backplane.Audio.Multipart do
  @moduledoc """
  Streaming `multipart/form-data` encoder for audio provider uploads.

  Produces the same bytes as the `encode_form_multipart/2` encoder from the req
  package that it replaces: every part is `--boundary CRLF`, a
  `content-disposition` line with an optional escaped `filename`, an optional
  `content-type` line, a blank line, the value and CRLF; the body ends with
  `--boundary-- CRLF`. `"`, CR and LF in
  parameter values are percent-encoded (RFC 7578).

  Field values are binaries/iodata, integers, or `%File.Stream{}`. File streams
  stay lazy; their size comes from `File.stat!/1` and their filename defaults to
  the path basename. Options per field are `:filename` and `:content_type`.
  """

  @crlf "\r\n"

  @type field ::
          {String.t() | atom(), iodata() | integer() | File.Stream.t() | {term(), keyword()}}

  @type t :: %{size: non_neg_integer(), content_type: String.t(), body: Enumerable.t()}

  @spec encode([field()], keyword()) :: t()
  def encode(fields, options \\ []) do
    options = Keyword.validate!(options, [:boundary])

    boundary =
      options[:boundary] ||
        Base.encode16(:crypto.strong_rand_bytes(16), padding: false, case: :lower)

    footer = [["--", boundary, "--", @crlf]]

    {body, size} =
      fields
      |> Enum.reduce({[], 0}, &add_parts(&2, encode_part(&1, boundary)))
      |> add_parts({footer, IO.iodata_length(footer)})

    %{size: size, content_type: "multipart/form-data; boundary=#{boundary}", body: body}
  end

  defp add_parts({parts1, size1}, {parts2, size2}) when is_list(parts1) and is_list(parts2),
    do: {[parts1, parts2], size1 + size2}

  defp add_parts({parts1, size1}, {parts2, size2}),
    do: {Stream.concat(parts1, parts2), size1 + size2}

  defp encode_part({name, {value, options}}, boundary) when is_atom(name) or is_binary(name) do
    options = Keyword.validate!(options, [:filename, :content_type])

    {parts, parts_size, options} =
      case value do
        integer when is_integer(integer) ->
          part = Integer.to_string(integer)
          {[part], byte_size(part), options}

        value when is_binary(value) or is_list(value) ->
          {[value], IO.iodata_length(value), options}

        %File.Stream{} = stream ->
          options = Keyword.put_new(options, :filename, Path.basename(stream.path))
          {stream, File.stat!(stream.path).size, options}
      end

    params =
      if filename = options[:filename],
        do: ["; filename=\"", escape(filename), "\""],
        else: []

    headers =
      if content_type = options[:content_type],
        do: ["content-type: ", escape(content_type), @crlf],
        else: []

    disposition = ["content-disposition: form-data; name=\"#{escape(to_string(name))}\""]
    header = [["--", boundary, @crlf, disposition, params, @crlf, headers, @crlf]]

    {header, IO.iodata_length(header)}
    |> add_parts({parts, parts_size})
    |> add_parts({[@crlf], 2})
  end

  defp encode_part({name, value}, boundary) when is_atom(name) or is_binary(name),
    do: encode_part({name, {value, []}}, boundary)

  defp escape(value) when is_binary(value), do: URI.encode(value, &(&1 not in [?", ?\r, ?\n]))
end
