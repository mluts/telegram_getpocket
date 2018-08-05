defmodule Tggp.Bot.UserSupervisor do
  use DynamicSupervisor

  def child_spec do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :supervisor
    }
  end

  def start_user(user_id) do
    DynamicSupervisor.start_child(__MODULE__, {Tggp.Bot.User, {:user_id, user_id}})
  end

  def start_link(arg) do
    DynamicSupervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end
end
