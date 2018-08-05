use Mix.Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :tggp, TggpWeb.Endpoint,
  http: [port: 4001],
  server: false

config :tggp,
  telegram_impl: Tggp.Telegram.Mock,
  getpocket_impl: Tggp.Getpocket.Mock,
  bot_couchdb_impl: Tggp.Bot.Couchdb.Mock

# Print only warnings and errors during test
config :logger, level: :warn
