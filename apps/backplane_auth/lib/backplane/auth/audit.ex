defmodule Backplane.Auth.Audit do
  @moduledoc "Audit event recording and queries for Backplane Auth."

  import Ecto.Query

  alias Backplane.Auth.Schemas.{AuditEvent, User}
  alias Backplane.Repo

  @secret_metadata_keys MapSet.new([
                          "access_token",
                          "authorization_code",
                          "client_secret",
                          "code",
                          "id_token",
                          "password",
                          "refresh_token",
                          "session_token",
                          "token"
                        ])

  def record(event_type, actor, attrs \\ %{}) when is_binary(event_type) and is_map(attrs) do
    attrs =
      attrs
      |> atom_key_attrs()
      |> Map.merge(actor_attrs(actor), fn _key, attr_value, actor_value ->
        attr_value || actor_value
      end)
      |> Map.put_new(:severity, "info")
      |> Map.update(:metadata, %{}, &sanitize_metadata/1)
      |> Map.put(:event_type, event_type)

    %AuditEvent{}
    |> AuditEvent.changeset(attrs)
    |> Repo.insert()
  end

  def list_events(filters \\ []) do
    filters = normalize_filters(filters)

    AuditEvent
    |> maybe_filter(:event_type, filters)
    |> maybe_filter(:severity, filters)
    |> maybe_filter(:target_type, filters)
    |> maybe_filter(:actor_type, filters)
    |> maybe_search(filters)
    |> order_by(desc: :inserted_at)
    |> Repo.all()
  end

  defp maybe_filter(query, field, filters) do
    case Map.get(filters, field) do
      value when is_binary(value) and value != "" ->
        where(query, [event], field(event, ^field) == ^value)

      _empty ->
        query
    end
  end

  defp maybe_search(query, filters) do
    case Map.get(filters, :search) do
      value when is_binary(value) and value != "" ->
        pattern = "%#{value}%"

        where(
          query,
          [event],
          ilike(event.event_type, ^pattern) or
            ilike(event.actor_id, ^pattern) or
            ilike(event.target_id, ^pattern)
        )

      _empty ->
        query
    end
  end

  defp actor_attrs(nil), do: %{}

  defp actor_attrs(%User{id: id}) do
    %{actor_type: "auth_user", actor_id: id}
  end

  defp actor_attrs(%{actor_type: actor_type, actor_id: actor_id}) do
    %{actor_type: actor_type, actor_id: actor_id}
  end

  defp actor_attrs(_actor), do: %{}

  defp atom_key_attrs(attrs) do
    Enum.reduce(attrs, %{}, fn
      {key, value}, acc when is_atom(key) -> Map.put(acc, key, value)
      {key, value}, acc when is_binary(key) -> Map.put(acc, String.to_atom(key), value)
    end)
  end

  defp normalize_filters(filters) when is_list(filters),
    do: filters |> Map.new() |> atom_key_attrs()

  defp normalize_filters(filters) when is_map(filters), do: atom_key_attrs(filters)

  defp sanitize_metadata(metadata) when is_map(metadata) do
    Enum.reduce(metadata, %{}, fn {key, value}, acc ->
      string_key = to_string(key)

      if MapSet.member?(@secret_metadata_keys, String.downcase(string_key)) do
        acc
      else
        Map.put(acc, string_key, sanitize_metadata(value))
      end
    end)
  end

  defp sanitize_metadata(metadata) when is_list(metadata),
    do: Enum.map(metadata, &sanitize_metadata/1)

  defp sanitize_metadata(value), do: value
end
