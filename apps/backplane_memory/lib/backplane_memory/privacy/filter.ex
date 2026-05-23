defmodule BackplaneMemory.Privacy.Filter do
  @moduledoc "Strips secrets and <private>-tagged content before memory storage."

  @secret_patterns [
    # OpenAI / Anthropic keys: sk- prefix + 20+ alphanumeric/hyphen/underscore chars
    ~r/sk-[A-Za-z0-9_\-]{20,}/,
    # AWS access key IDs
    ~r/AKIA[0-9A-Z]{16}/,
    # Explicit api_key / access_token assignments
    ~r/(?i)(?:api[_-]?key|access[_-]?token|bearer)[[:space:]]*[:=][[:space:]]*["']?(?:[A-Za-z0-9+\/\-_]{20,})["']?/
  ]

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
    Enum.reduce(@secret_patterns, content, fn pattern, acc ->
      Regex.replace(pattern, acc, "[REDACTED]")
    end)
  end
end
