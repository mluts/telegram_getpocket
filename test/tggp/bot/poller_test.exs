defmodule Tggp.Bot.PollerTest do
  use ExUnit.Case

  alias Tggp.Bot.Poller
  alias Nadia.Model.{Update}

  setup do
    Mox.set_mox_global()
  end

  test "it polls for new updates" do
    parent = self()
    update = %Update{}

    Mox.expect(Tggp.Telegram.Mock, :get_updates, fn _offset ->
      {:ok, [update]}
    end)

    _pid = start_supervised!({Poller, [fn u ->
      send(parent, {:update, u})

      receive do
        :continue -> nil
      end
    end]})

    receive do
      {:update, u} ->
        assert update == u
    after
      3000 ->
        flunk("didn't receive an update!")
    end
  end
end
