defmodule Backplane.JsonSchema.URIUtil do
  @moduledoc """
  Utilities for URI resolution and manipulation without implicit network access.
  """

  @doc """
  Resolves a relative URI against a base URI.
  """
  @spec resolve(String.t() | nil, String.t() | nil) :: String.t() | nil
  def resolve(nil, uri), do: uri
  def resolve(base, nil), do: base

  def resolve(base, uri) when is_binary(base) and is_binary(uri) do
    cond do
      filesystem_path_uri?(base) ->
        resolve_filesystem_path(base, uri)

      true ->
        try do
          base |> URI.merge(uri) |> URI.to_string()
        rescue
          _ -> uri
        end
    end
  end

  @doc """
  Splits a URI or reference into `{base, fragment}`.
  """
  @spec split_fragment(String.t()) :: {String.t(), String.t() | nil}
  def split_fragment(""), do: {"", nil}
  def split_fragment("#"), do: {"", nil}

  def split_fragment(uri) when is_binary(uri) do
    case :binary.split(uri, "#", []) do
      [base, ""] -> {base, nil}
      [base, fragment] -> {base, fragment}
      [base] -> {base, nil}
    end
  end

  @doc """
  Returns the URI or reference without its fragment.
  """
  @spec base(String.t() | nil) :: String.t() | nil
  def base(nil), do: nil

  def base(uri) when is_binary(uri) do
    case :binary.match(uri, "#") do
      {offset, 1} -> binary_part(uri, 0, offset)
      _ -> uri
    end
  end

  @doc """
  Returns only the fragment portion of a URI or reference, without the leading `#`.
  """
  @spec fragment(String.t()) :: String.t() | nil
  def fragment(uri) when is_binary(uri) do
    {_base, fragment} = split_fragment(uri)
    fragment
  end

  @doc """
  Joins a fragment-free base URI and a fragment into a URI reference.
  """
  @spec join_fragment(String.t(), String.t() | nil) :: String.t()
  def join_fragment(base, nil) when is_binary(base), do: base

  def join_fragment(base, fragment) when is_binary(base) and is_binary(fragment) do
    base <> "#" <> fragment
  end

  @doc """
  Converts a fragment into a local reference string.
  """
  @spec local_ref(String.t() | nil) :: String.t()
  def local_ref(nil), do: "#"
  def local_ref(fragment) when is_binary(fragment), do: "#" <> fragment

  @doc """
  Checks if a reference string represents a remote URI (http or https).
  """
  @spec remote_ref?(String.t()) :: boolean()
  def remote_ref?(<<h, t, t2, p, ?:, ?/, ?/, _rest::binary>>)
      when (h == ?h or h == ?H) and (t == ?t or t == ?T) and (t2 == ?t or t2 == ?T) and (p == ?p or p == ?P),
      do: true

  def remote_ref?(<<h, t, t2, p, s, ?:, ?/, ?/, _rest::binary>>)
      when (h == ?h or h == ?H) and (t == ?t or t == ?T) and (t2 == ?t or t2 == ?T) and
             (p == ?p or p == ?P) and (s == ?s or s == ?S),
      do: true

  def remote_ref?(_), do: false

  @doc false
  def external_ref?(ref) when is_binary(ref), do: base(ref) != ""
  def external_ref?(_), do: false

  defp filesystem_path_uri?(uri) when is_binary(uri) do
    String.starts_with?(uri, "/") and URI.parse(uri).scheme == nil
  end

  defp resolve_filesystem_path(base, "#" <> _ = fragment_ref) do
    base_without_fragment = base(base)
    base_without_fragment <> fragment_ref
  end

  defp resolve_filesystem_path(base, uri) do
    case URI.parse(uri) do
      %{scheme: scheme} when is_binary(scheme) ->
        uri

      _ ->
        {uri_path, uri_fragment} = split_fragment(uri)

        resolved_path =
          if String.starts_with?(uri_path, "/") do
            uri_path
          else
            base_path = base(base)
            expanded_path = Path.expand(uri_path, Path.dirname(base_path))

            if String.ends_with?(uri_path, "/") do
              expanded_path <> "/"
            else
              expanded_path
            end
          end

        join_fragment(resolved_path, uri_fragment)
    end
  end
end
