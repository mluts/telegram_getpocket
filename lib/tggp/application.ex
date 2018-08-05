defmodule Tggp.Application do
  use Application

  # See https://hexdocs.pm/elixir/Application.html
  # for more information on OTP Applications
  def start(_type, opts) do
    # Define workers and child supervisors to be supervised

    children =
      case opts[:env] do
        :test ->
          [{TggpWeb.Endpoint, []}]

        _ ->
          [{TggpWeb.Endpoint, []},
           {Tggp.Bot.Supervisor, []}
          ]
      end

    # See https://hexdocs.pm/elixir/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Tggp.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  def config_change(changed, _new, removed) do
    TggpWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
