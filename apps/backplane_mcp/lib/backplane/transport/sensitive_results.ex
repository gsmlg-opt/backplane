defmodule Backplane.Transport.SensitiveResults do
  @moduledoc false

  # Issuance results contain a secret delivered only in the immediate response.
  def tool?("admin::upsert-client"), do: true
  def tool?(_name), do: false

  def request?(messages) when is_list(messages), do: Enum.any?(messages, &request?/1)

  def request?(%{"method" => method, "params" => %{"name" => name}} = message)
      when method in ["tools/call", "tasks/create"],
      do: tool?(name) or request?(message["_json"])

  def request?(%{"_json" => messages}) when is_list(messages), do: request?(messages)

  def request?(_message), do: false
end
