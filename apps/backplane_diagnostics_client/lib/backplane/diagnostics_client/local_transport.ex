defmodule Backplane.DiagnosticsClient.LocalTransport do
  @moduledoc "Sends authenticated diagnostics batches to a configured Host Agent HTTP endpoint."

  alias Backplane.DiagnosticsClient.Receipt

  @max_reply_bytes 64 * 1024

  def sender(opts, source_id) do
    %URI{scheme: scheme, host: host, userinfo: nil, fragment: nil, query: nil} =
      uri =
      URI.parse(Keyword.fetch!(opts, :host_url))

    true = scheme in ~w(http https) and is_binary(host) and host != ""
    url = URI.to_string(%{uri | path: "/diagnostics/v1/events"}) |> String.to_charlist()
    token_env = Keyword.fetch!(opts, :token_env)
    source = String.to_charlist(source_id)

    fn batch ->
      with token when is_binary(token) and byte_size(token) in 24..256 <-
             System.get_env(token_env),
           {:ok, body} <- Receipt.encode_batch(batch) do
        headers = [
          {~c"x-backplane-diagnostics-source", source},
          {~c"authorization", ~c"Bearer " ++ String.to_charlist(token)}
        ]

        options = [autoredirect: false, connect_timeout: 1_000, timeout: 3_000]

        options =
          if scheme == "https" do
            Keyword.put(options, :ssl, :httpc.ssl_verify_host_options(true))
          else
            options
          end

        :httpc.request(:post, {url, headers, ~c"application/json", body}, options,
          body_format: :binary
        )
        |> response()
      else
        {:error, _} = error -> error
        _ -> {:error, :unauthorized}
      end
    end
  end

  defp response({:ok, {{_, 200, _}, _, bytes}}) when byte_size(bytes) <= @max_reply_bytes do
    case Formata.JSON.decode(bytes) do
      {:ok, result} -> {:ok, result}
      {:error, _} -> {:error, :invalid_receipt}
    end
  end

  defp response({:ok, {{_, code, _}, _, _}}) when code in [401, 403], do: {:error, :unauthorized}
  defp response({:ok, {{_, 413, _}, _, _}}), do: {:error, :batch_too_large}
  defp response({:ok, {{_, 200, _}, _, _}}), do: {:error, :invalid_receipt}
  defp response(_), do: {:error, :host_unavailable}
end
