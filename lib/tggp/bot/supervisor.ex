defmodule Tggp.Bot.Supervisor do
  use Supervisor
  require Logger

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  def init(_arg) do
    children = [
      {Tggp.Bot.Poller, [&Tggp.Bot.User.dispatch/1]},
      {Registry, keys: :unique, name: Tggp.Bot.UsersRegistry},
      Tggp.Bot.UserSupervisor
    ]

    Logger.info "Starting bot supervisor"

    Supervisor.init(children, strategy: :one_for_all)
  end
end
