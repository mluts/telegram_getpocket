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
        state = %BotUser.State{getpocket_access_token: at, user_id: user.id}
        {:ok, %HTTPoison.Response{status_code: 200, body: Poison.encode!(state)}}
      end)

      Mox.expect(CouchdbMock, :put_document, 1, fn _key, _rev, _doc ->
        {:ok, %HTTPoison.Response{status_code: 200, body: Poison.encode!(%{})}}
      end)

      Mox.expect(GetpocketMock, :get_articles, 1, fn ^at, [count: 1000] ->
        articles = for _ <- 1..10, do: %Getpocket.Api.Article{}
        {:ok, articles}
      end)

      Mox.expect(TelegramMock, :send_message, 1, fn _chat_id, _msg -> nil end)

      upd |> put_command("/rand") |> BotUser.dispatch()
      :sys.get_state(BotUser.process_name(user.id))
    end
  end

  describe "/daily" do
    test "creates subscription for random article", %{user: user, update: upd} do
      at = "access token"

      Mox.expect(CouchdbMock, :get_document, 1, fn key ->
        assert key == "user_state_#{to_string(user.id)}"
        state = %BotUser.State{getpocket_access_token: at, user_id: user.id}
        {:ok, %HTTPoison.Response{status_code: 200, body: Poison.encode!(state)}}
      end)

      Mox.expect(CouchdbMock, :put_document, 1, fn _key, _rev, _doc ->
        {:ok, %HTTPoison.Response{status_code: 200, body: Poison.encode!(%{})}}
      end)

      upd |> put_command("/daily 11:35") |> BotUser.dispatch()
      state = :sys.get_state(BotUser.process_name(user.id))

      expected_time = ~T[11:35:00]
      assert state.daily_article_schedule == expected_time

      expected_datetime =
        Timex.now()
        |> Timex.shift(days: 1)
        |> Map.put(:hour, expected_time.hour)
        |> Map.put(:minute, expected_time.minute)
        |> DateTime.truncate(:second)

      assert state.next_daily_article_at == expected_datetime
    end

    test "sending daily message", %{user: user} do
      at = "access_token"

      dt = Timex.now() |> Timex.shift(hours: -1) |> DateTime.truncate(:second)

      Mox.expect(CouchdbMock, :get_document, fn key ->
        assert key == "user_state_#{to_string(user.id)}"

        state = %BotUser.State{
          getpocket_access_token: at,
          user_id: user.id,
          next_daily_article_at: dt,
          daily_article_schedule: DateTime.to_time(dt)
        }

        {:ok, %HTTPoison.Response{status_code: 200, body: Poison.encode!(state)}}
      end)

      Mox.expect(CouchdbMock, :put_document, fn _key, _rev, _doc ->
        {:ok, %HTTPoison.Response{status_code: 200, body: Poison.encode!(%{})}}
      end)

      Mox.expect(TelegramMock, :send_message, fn _chat_id, _msg -> nil end)

      Mox.expect(GetpocketMock, :get_articles, fn _access_token, _opts ->
        articles = for _ <- 1..10, do: %Getpocket.Api.Article{}
        {:ok, articles}
      end)

      BotUser.ensure_started!(user.id)

      Registry.dispatch(Tggp.Bot.UsersRegistry, BotUser.process_key(user.id), fn [{pid, _}] ->
        send(pid, :check_daily_article)
      end)

      :sys.get_state(BotUser.process_name(user.id))
    end
  end
end
