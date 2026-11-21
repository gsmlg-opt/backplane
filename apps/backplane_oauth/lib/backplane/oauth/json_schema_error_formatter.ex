defmodule Backplane.Oauth.JsonSchemaErrorFormatter do
  @moduledoc false

  alias Formata.Error

  @spec format([Error.t()]) :: [String.t()]
  def format(errors), do: Enum.map(errors, &format_error/1)

  defp format_error(%Error{code: :required, path: path, details: %{contrast: [missing]}}) do
    "Required property #{missing} is missing at #{fragment(path)}."
  end

  defp format_error(%Error{code: :required, path: path, details: %{contrast: missing}}) do
    "Required properties #{Enum.join(missing, ", ")} are missing at #{fragment(path)}."
  end

  defp format_error(%Error{code: :pattern, path: path, details: %{contrast: %Regex{} = regex}}) do
    "#{fragment(path)} do match required pattern /#{Regex.source(regex)}/."
  end

  defp format_error(%Error{
         code: :type,
         path: path,
         details: %{input: actual, contrast: expected}
       }) do
    "The type at #{fragment(path)} `#{actual}` do not match the required types #{inspect(List.wrap(expected))}."
  end

  # Backend messages can include submitted values.
  defp format_error(%Error{}), do: "Invalid request parameter."

  defp fragment([]), do: "#"
  defp fragment(path), do: "#" <> Error.format_path(path)
end
