defmodule Backplane.MemoryRepository do
  @moduledoc """
  Pure repository provenance normalization shared by capture and canonical writes.

  Repository IDs omit transport credentials and standard SSH/HTTPS transport
  differences. Paths remain case sensitive; nonstandard ports remain distinct.
  Local paths never imply a remote repository identity.
  """

  @doc "Normalizes a remote without network access; unsupported/local remotes return nil."
  def normalize_remote(remote) when is_binary(remote) do
    remote = String.trim(remote)

    cond do
      Regex.match?(~r/^[A-Za-z]:[\\\/]/, remote) ->
        nil

      String.contains?(remote, "://") ->
        normalize_uri(URI.parse(remote))

      Regex.match?(~r/^(?:[^\s\/@:]+@)?[^\s\/:]+:.+$/, remote) ->
        normalize_scp(remote)

      true ->
        nil
    end
  rescue
    _ in [ArgumentError, URI.Error] -> nil
  end

  def normalize_remote(_remote), do: nil

  @doc "Validates an already normalized source ID, or normalizes an explicit remote URL."
  def normalize_identifier(id) when is_binary(id) do
    if Regex.match?(~r/^(?:\[[0-9a-fA-F:]+\]|[^\s\/:@]+)(?::\d+)?\/[^\s]+$/, id) do
      %URI{host: host, port: port, path: path} = URI.parse("git-source://" <> id)
      identity(host, port, path)
    else
      normalize_remote(id)
    end
  rescue
    _ in [ArgumentError, URI.Error] -> nil
  end

  def normalize_identifier(_id), do: nil

  @doc "Selects origin, otherwise the only configured remote; ambiguity stays unresolved."
  def select_remote(remotes) when is_map(remotes) do
    case Map.fetch(remotes, "origin") do
      {:ok, remote} ->
        normalize_remote(remote)

      :error ->
        if map_size(remotes) == 1, do: remotes |> Map.values() |> hd() |> normalize_remote()
    end
  end

  @doc "Validates source records and strips any remote credentials before storage/display."
  def sources(value) when is_list(value) do
    value
    |> Enum.filter(&is_map/1)
    |> Enum.map(fn source ->
      %{
        "repository_id" => normalize_identifier(value(source, "repository_id")),
        "checkout_root" => string(value(source, "checkout_root")),
        "cwd" => string(value(source, "cwd"))
      }
    end)
    |> Enum.reject(&Enum.all?(Map.values(&1), fn value -> is_nil(value) end))
    |> Enum.uniq()
    |> Enum.sort_by(&{&1["repository_id"], &1["checkout_root"], &1["cwd"]})
  end

  def sources(_value), do: []

  @doc "Retains historical metadata while canonicalizing the additive source list."
  def metadata(metadata, additional \\ [])

  def metadata(metadata, additional) when is_map(metadata) do
    sources = sources(List.wrap(value(metadata, "repository_sources")) ++ additional)
    metadata = Map.drop(metadata, ["repository_sources", :repository_sources])
    if sources == [], do: metadata, else: Map.put(metadata, "repository_sources", sources)
  end

  def metadata(metadata, _additional), do: metadata

  defp normalize_scp(remote) do
    case Regex.run(~r/^(?:[^\s\/@:]+@)?([^\s\/:]+):(.+)$/, remote) do
      [_, host, path] -> identity(host, nil, path)
      _ -> nil
    end
  end

  defp normalize_uri(%URI{scheme: scheme, host: host, path: path, port: port})
       when scheme in ["ssh", "https", "http", "git"] and is_binary(host) do
    port =
      if {scheme, port} in [{"ssh", 22}, {"https", 443}, {"http", 80}, {"git", 9418}],
        do: nil,
        else: port

    identity(host, port, path)
  end

  defp normalize_uri(_uri), do: nil

  defp identity(host, port, path) when is_binary(path) do
    path =
      path
      |> String.trim_leading("/")
      |> String.trim_trailing("/")
      |> String.replace(~r/\.git$/, "")

    parts = String.split(path, "/")

    if host not in ["", ".", ".."] and path != "" and
         Enum.all?(
           parts,
           &(&1 not in ["", ".", "..", "~"] and not String.match?(&1, ~r/[\s?#@\\]/))
         ) do
      host = String.downcase(host)
      host = if String.contains?(host, ":"), do: "[" <> host <> "]", else: host
      host <> if(port, do: ":#{port}/", else: "/") <> path
    end
  end

  defp identity(_host, _port, _path), do: nil

  defp value(map, key),
    do:
      Map.get(map, key) ||
        Enum.find_value(map, fn {k, v} -> if is_atom(k) and Atom.to_string(k) == key, do: v end)

  defp string(value) when is_binary(value), do: if(String.trim(value) == "", do: nil, else: value)
  defp string(_value), do: nil
end
