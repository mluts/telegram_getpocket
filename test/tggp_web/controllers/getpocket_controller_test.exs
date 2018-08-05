defmodule TggpWeb.GetpocketControllerTest do
  use TggpWeb.ConnCase

  setup do
    start_supervised!({Registry, keys: :unique, name: Tggp.Bot.UsersRegistry})
    start_supervised!(Tggp.Bot.UserSupervisor)
    user_id = 123

    Mox.verify_on_exit!()
    Mox.set_mox_global()


    %{
      user_id: user_id
    }
  end

  test "GET /getpocket/:user_id/auth_done", %{conn: conn, user_id: user_id} do
    Mox.expect(Tggp.Bot.Couchdb.Mock, :get_document, 1, fn _id ->
      body = %Tggp.Bot.User.State{getpocket_request_token: "request_token"}
             |> Poison.encode!()
      {:ok, %HTTPoison.Response{status_code: 200, body: body}}
    end)

    Mox.expect(Tggp.Getpocket.Mock, :get_access_token, 1, fn _rt ->
      {:ok, %{"access_token" => "access token"}}
    end)

    Mox.expect(Tggp.Telegram.Mock, :send_message, 1, fn _cid, _msg -> nil end)

    path = getpocket_path(conn, :auth_done, user_id)
    conn = get(conn, path)

    assert html_response(conn, 200)
  end
end
