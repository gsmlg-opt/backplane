defmodule Backplane.LLM.ResponsesWebSocket.Limits do
  @moduledoc false

  @term_defaults %{
    max_depth: 320,
    max_map_entries: 5_120,
    max_list_length: 40_960,
    max_bytes: 10_485_760,
    max_string_bytes: 2_621_440,
    max_nodes: 327_680
  }
  @defaults Map.merge(@term_defaults, %{
              max_message_bytes: 20_971_520,
              max_response_ids: 20_480
            })
  @term_keys Map.keys(@term_defaults)

  def current do
    Map.merge(@defaults, Application.get_env(:backplane_llama, __MODULE__, %{}))
  end

  def codec_options(limits) do
    [max_encoded_bytes: limits.max_message_bytes, limits: Map.take(limits, @term_keys)]
  end
end
