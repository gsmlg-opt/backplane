{
  pkgs,
  lib,
  config,
  inputs,
  ...
}: let
  pkgs-stable = import inputs.nixpkgs-stable {system = pkgs.stdenv.system;};
  hostAgentConfig = "${config.devenv.state}/host-agent/host_agent.yaml";
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
      ffmpeg-full
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
    env.BACKPLANE_HOST_AGENT_CONFIG = hostAgentConfig;
    exec = ''
      set -e
      echo "Waiting for PostgreSQL..."
      while ! pg_isready -h "$PGHOST" -d backplane_dev -q 2>/dev/null; do
        sleep 0.5
      done
      echo "PostgreSQL is ready, preparing database..."
      mix ecto.create --quiet
      mix ecto.migrate
      echo "Preparing the local host agent..."
      mix run --no-start scripts/setup_devenv_host_agent.exs
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

  processes.host-agent = {
    after = ["devenv:processes:backplane"];
    cwd = "${config.git.root}/apps/backplane_host_agent";
    env = {
      BACKPLANE_HOST_AGENT_CONFIG = hostAgentConfig;
      ELIXIR_ERL_OPTIONS = "${config.env.ELIXIR_ERL_OPTIONS} -start_epmd false";
    };
    exec = "exec mix agent.run";

    ready = {
      exec = ''
        ${pkgs.curl}/bin/curl --fail --silent --output /dev/null \
          --header 'content-type: application/json' \
          --data '{"limit":1}' \
          http://127.0.0.1:4222/memory/devenv/call/list
      '';
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
