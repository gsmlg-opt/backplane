defmodule BackplaneMemory.Privacy.Filter do
  @moduledoc "Strips secrets and <private>-tagged content before memory storage."

  @spec apply(String.t()) :: {:ok, String.t()}
  def apply(content) when is_binary(content) do
    result =
      content
      |> strip_private_tags()
      |> redact_secrets()

    {:ok, result}
  end

  def apply(_content), do: {:ok, ""}

  defp strip_private_tags(content) do
    Regex.replace(~r/<private>.*?<\/private>/s, content, "[REDACTED]")
  end

  defp redact_secrets(content) do
    Enum.reduce(secret_patterns(), content, fn pattern, acc ->
      Regex.replace(pattern, acc, "[REDACTED]")
    end)
  end

  # Compiled regexes with POSIX classes contain erlang references which cannot be
  # stored as module attributes in Elixir 1.18 — define as a function instead.
  defp secret_patterns do
    [
      ~r/sk-[A-Za-z0-9_\-]{20,}/,
      ~r/AKIA[0-9A-Z]{16}/,
      ~r/gh[pohur]_[A-Za-z0-9]{36,}/,
      ~r/(?i)(?:api[_-]?key|access[_-]?token)[[:space:]]*[:=][[:space:]]*["']?(?:[A-Za-z0-9+\/\-_]{20,})["']?/,
      ~r/(?i)Authorization[[:space:]]*:[[:space:]]*Bearer[[:space:]]+[A-Za-z0-9\-._~+\/]+=*/
    ]
  end
end
