Postgrex.Types.define(
  Backplane.PostgrexTypes,
  Pgvector.extensions() ++ Ecto.Adapters.Postgres.extensions(),
  []
)
