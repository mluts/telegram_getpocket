defmodule Tggp.Bot.ServerTest do
  use ExUnit.Case

  alias Tggp.Bot.Server
  alias Nadia.Model.{Message, Chat, User}
  alias Tggp.Getpocket.Mock, as: GetpocketMock
  alias Tggp.Telegram.Mock, as: TelegramMock
  import TggpWeb.Router.Helpers

  setup ctx do
    user = %User{
      id: 123
    }

    chat = %Chat{
      id: 123
    }

    Mox.allow(TelegramMock, self(), Process.whereis(Server))
    Mox.allow(GetpocketMock, self(), Process.whereis(Server))

    Map.merge(ctx, %{
      pid: Server,
      user: user,
      chat: chat,
      request_token: "REQUEST_TOKEN"
    })
  end

  test "true", %{pid: pid, chat: chat, user: user, request_token: rt} do
    auth_uri = URI.parse("http://example.com")

    Mox.expect(TelegramMock, :send_message, 2, fn cid, _msg ->
      assert cid == chat.id
    end)

    Mox.expect(GetpocketMock, :get_request_token, fn redirect_uri ->
      assert redirect_uri == getpocket_url(TggpWeb.Endpoint, :auth_done, user.id)
      {:ok, rt}
    end)

    Mox.expect(GetpocketMock, :get_authorization_url, fn rt_, _uri ->
      assert rt == rt_
      auth_uri
    end)

    GenServer.cast(pid, {:command, "/start", %Message{chat: chat, from: user}})

    :sys.get_state(pid)
  end
end
