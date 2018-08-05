defmodule Tggp.Bot.UserTest do
  use ExUnit.Case

  alias Nadia.Model.{User, Message, Chat, Update}
  alias Tggp.Bot.User, as: BotUser
  alias Tggp.Telegram.Mock, as: TelegramMock
  alias Tggp.Getpocket.Mock, as: GetpocketMock
  alias Tggp.Bot.Couchdb.Mock, as: CouchdbMock

  import TggpWeb.Router.Helpers

  setup do
    start_supervised!({Registry, keys: :unique, name: Tggp.Bot.UsersRegistry})
    start_supervised!(Tggp.Bot.UserSupervisor)

    chat = %Chat{id: 123}
    user = %User{id: 123}
    msg = %Message{from: user, chat: chat}
    update = %Update{message: msg}

    Mox.verify_on_exit!()
    Mox.set_mox_global()

    %{
      user: user,
      chat: chat,
      msg: msg,
      update: update
    }
  end

  def put_command(%Update{message: msg} = upd, cmd) do
    %{upd | message: %{msg | text: cmd}}
  end

  describe "dispatching message" do
    test "autostarts user process", %{update: upd, user: user} do
      Mox.expect(CouchdbMock, :get_document, 1, fn _id ->
        {:ok, %HTTPoison.Response{status_code: 404}}
      end)
      assert Registry.lookup(Tggp.Bot.UsersRegistry, {:user, user.id}) |> Enum.empty?()

      BotUser.dispatch(upd)
      [{pid, _}] = Registry.lookup(Tggp.Bot.UsersRegistry, {:user, user.id})
      assert is_pid(pid)
    end
  end

  describe "/start" do
    test "shows an auth link", %{update: upd, user: user} do
      request_token = "rt"
      auth_url = "url"

      Mox.expect(CouchdbMock, :get_document, 1, fn _id ->
        {:ok, %HTTPoison.Response{status_code: 404}}
      end)
      Mox.expect(TelegramMock, :send_message, 2, fn _chat_id, _msg -> nil end)
      Mox.expect(GetpocketMock, :get_request_token, fn redirect_uri ->
        assert redirect_uri == getpocket_url(TggpWeb.Endpoint, :auth_done, user.id)
        {:ok, request_token}
      end)
      Mox.expect(GetpocketMock, :get_authorization_url, fn _request_token, _redirect_uri ->
        auth_url
      end)

      upd
      |> put_command("/start")
      |> BotUser.dispatch()

      :sys.get_state(BotUser.process_name(user.id))
    end

    test "doesnt do anything if already have access token", %{update: upd, user: user} do
      at = "access token"

      state = %BotUser.State{getpocket_access_token: at}

      Mox.expect(CouchdbMock, :get_document, 1, fn _id ->
        {:ok, %HTTPoison.Response{status_code: 200, body: Poison.encode!(state)}}
      end)
      Mox.expect(TelegramMock, :send_message, 1, fn _chat_id, _msg -> nil end)

      upd |> put_command("/start") |> BotUser.dispatch()
      :sys.get_state(BotUser.process_name(user.id))
    end
  end

  describe "/rand" do
    test "sends random article", %{user: user, update: upd} do
      at = "access token"

      Mox.expect(CouchdbMock, :get_document, 1, fn key ->
        assert key == "user_state_#{to_string(user.id)}"
        state = %BotUser.State{getpocket_access_token: at}
        {:ok, %HTTPoison.Response{status_code: 200, body: Poison.encode!(state)}}
      end)

      Mox.expect(GetpocketMock, :get_articles, 1, fn ^at, [count: 1000] ->
        articles = for _ <- (1..10), do: %Getpocket.Api.Article{}
        {:ok, articles}
      end)

      Mox.expect(TelegramMock, :send_message, 1, fn _chat_id, _msg -> nil end)

      upd |> put_command("/rand") |> BotUser.dispatch()
      :sys.get_state(BotUser.process_name(user.id))
    end
  end
end
