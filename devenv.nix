{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: let
  pkgs-stable = import inputs.nixpkgs-stable {system = pkgs.stdenv.system;};
in {
  env.GREET = "Backplane";
  # Disable the Erlang break menu so Ctrl+C stops service-like Mix tasks
  # such as `mix agent.run` instead of leaving the BEAM at a BREAK prompt.
  env.ELIXIR_ERL_OPTIONS = "+B";
  env.MIX_TAILWIND_PATH = "${pkgs-stable.tailwindcss_4}/bin/tailwindcss";
  env.MIX_BUN_PATH = "${pkgs-stable.bun}/bin/bun";
  env.NODE_PATH = "${config.git.root}/deps";

  packages = with pkgs-stable;
    [
      git
      figlet
      lolcat
      watchman
      tailwindcss_4
      pkg-config
      openssl
      cargo
      rustc
      beam28Packages.elixir-ls
    ]
    ++ lib.optionals stdenv.isLinux [
      inotify-tools
    ];

  languages.elixir.enable = true;
  languages.elixir.package = pkgs-stable.beam28Packages.elixir;

  languages.javascript.enable = true;
  languages.javascript.pnpm.enable = true;
  languages.javascript.bun.enable = true;
  languages.javascript.bun.package = pkgs-stable.bun;

  processes.backplane = {
    exec = ''
      echo "Waiting for PostgreSQL..."
      while ! pg_isready -h "$PGHOST" -d backplane_dev -q 2>/dev/null; do
        sleep 0.5
      done
      echo "PostgreSQL is ready, preparing database..."
      mix ecto.create --quiet
      mix ecto.migrate
      echo "Database is ready, starting backplane..."
      exec mix backplane.run
    '';

    ready = {
      http.get = {
        host = "127.0.0.1";
        port = 4220;
        path = "/";
      };
      period = 1;
      probe_timeout = 5;
      timeout = 120;
    };
  };

  services.postgres = {
    enable = true;
    package = pkgs-stable.postgresql_17.withPackages (ps: [
      ps.pgvector
    ]);
    initialDatabases = [
      {name = "backplane_dev";}
      {name = "backplane_test";}
    ];
  };

  scripts.hello.exec = ''
    figlet -w 120 $GREET | lolcat
  '';

  enterShell = ''
    hello
  '';
}
