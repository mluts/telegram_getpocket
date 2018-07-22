# This file is responsible for configuring your application
# and its dependencies with the aid of the Mix.Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.
use Mix.Config

# General application configuration
config :tggp,
  ecto_repos: [Tggp.Repo]

# Configures the endpoint
config :tggp, TggpWeb.Endpoint,
  url: [host: "localhost"],
  secret_key_base: "d3t8FnNR59vsGH8nYinrwjXJMkeBc3G4rIqIzxgfwS3VnSwcspdld1fomi/zBk04",
  render_errors: [view: TggpWeb.ErrorView, accepts: ~w(html json)],
  pubsub: [name: Tggp.PubSub,
           adapter: Phoenix.PubSub.PG2]

# Configures Elixir's Logger
config :logger, :console,
  format: "$time $metadata[$level] $message\n",
  metadata: [:user_id]

config :nadia,
  token: {:system, "TELEGRAM_DEV_BOT_TOKEN"}

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{Mix.env}.exs"
