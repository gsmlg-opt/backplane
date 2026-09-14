defmodule Backplane.SkillProtocol.Transport.Req do
  @moduledoc false

  @spec request(map()) :: {:ok, map()} | {:error, term()}
  def request(request) do
    into = fn {:data, chunk}, {req, response} ->
      body = [response.body || [], chunk]
      size = (response.private[:skill_protocol_bytes] || 0) + byte_size(chunk)

      cond do
        request.cancelled?.() ->
          {:halt, {req, put_result(response, {:error, :cancelled}, size)}}

        System.monotonic_time(:millisecond) >= request.deadline ->
          {:halt, {req, put_result(response, {:error, :timeout}, size)}}

        size > request.max_bytes ->
          {:halt, {req, put_result(response, {:error, :response_too_large}, size)}}

        true ->
          response = %{response | body: body}
          {:cont, {req, put_in(response.private[:skill_protocol_bytes], size)}}
      end
    end

    case Req.get(
           url: request.url,
           headers: request.headers,
           redirect: false,
           max_retries: 0,
           decode_body: false,
           receive_timeout: request.timeout_ms,
           connect_options: [timeout: request.timeout_ms],
           into: into
         ) do
      {:ok, response} -> normalize(response)
      {:error, exception} -> {:error, exception}
    end
  rescue
    exception -> {:error, exception}
  end

  defp normalize(%Req.Response{private: %{skill_protocol_result: {:error, reason}}}),
    do: {:error, reason}

  defp normalize(%Req.Response{} = response) do
    {:ok,
     %{
       status: response.status,
       headers:
         response.headers
         |> Enum.into(%{})
         |> Map.new(fn {key, values} -> {key, List.first(values)} end),
       body: IO.iodata_to_binary(response.body || [])
     }}
  end

  defp put_result(response, result, size) do
    response
    |> put_in([Access.key(:private), :skill_protocol_result], result)
    |> put_in([Access.key(:private), :skill_protocol_bytes], size)
  end
end
