import Config

if config_env() == :prod do
  config_path = System.get_env("BACKPLANE_CONFIG", "backplane.toml")

  if File.exists?(config_path) do
    backplane_config = Backplane.Config.load!(config_path)

    if db_url = backplane_config[:database][:url] do
      config :backplane, Backplane.Repo, url: db_url
    end
  end
end
