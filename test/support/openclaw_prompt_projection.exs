defmodule Backplane.OpenClawPromptProjection do
  @moduledoc false

  # The host may append runtime context with role=user after the actual input.
  # Inspect the model projection of this turn, rather than the last role or history.
  def current_user_text(%{"prompt" => prompt, "finalPrompt" => messages})
      when is_binary(prompt) and prompt != "" and is_list(messages) do
    messages
    |> Enum.reverse()
    |> Enum.filter(&(&1["role"] == "user"))
    |> Enum.map(&text(&1["content"]))
    |> Enum.find("", &String.contains?(&1, prompt))
  end

  def current_user_text(_), do: ""

  defp text(content) when is_binary(content), do: content

  defp text(content) when is_list(content),
    do: Enum.map_join(content, "\n", &Map.get(&1, "text", ""))

  defp text(_), do: ""
end
