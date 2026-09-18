[
  import_deps: [:ecto, :ecto_sql, :plug],
  # TODO(upstream): duskmoon-dev/phoenix-duskmoon-ui#166
  subdirectories: ["priv/*/migrations"],
  inputs: ["{mix,.formatter}.exs", "{config,lib,test}/**/*.{ex,exs}", "priv/*/seeds.exs"]
]
