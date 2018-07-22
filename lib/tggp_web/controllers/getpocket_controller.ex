defmodule TggpWeb.GetpocketController do
  use TggpWeb, :controller

  def auth_done(conn, %{"user_id" => user_id_str}) do
    {user_id, _} = Integer.parse(user_id_str)
    :ok = GenServer.call(Tggp.Bot.Server, {:auth_done, user_id})
    render conn, "auth_done.html"
  end
end
