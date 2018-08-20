defmodule Tggp.Bot.User do
  use GenServer
  require Logger
  import Tggp.Gettext
  import TggpWeb.Router.Helpers

  alias Tggp.Bot.{UsersRegistry, UserSupervisor}
  alias Getpocket.Api.Article
  alias Nadia.Model.{User, Message, Update}
  alias HTTPoison.Response

  @daily_articles_check_period_ms 1000 * 60

  defmodule State do
    @derive {Poison.Encoder, except: ~w(_rev _id)a}

    defimpl Poison.Decoder, for: __MODULE__ do
      def decode(value, _opts) do
        value
        |> Map.update(:next_daily_article_at, nil, &parse_datetime/1)
        |> Map.update(:daily_article_schedule, nil, &parse_time/1)
      end

      defp parse_time(str) do
        case Timex.parse(str, "{h24}:{m}:{s}") do
          {:ok, nt} -> nt |> NaiveDateTime.to_time()
          _ -> nil
        end
      end

      defp parse_datetime(str) do
        case Timex.parse(str, "{ISO:Extended}") do
          {:ok, dt} ->
            dt

          _ ->
            nil
        end
      end
    end

    defstruct user_id: nil,
              chat_id: nil,
              messages_cache: [],
              getpocket_access_token: nil,
              getpocket_request_token: nil,
              getpocket_articles_cache: [],
              daily_article_schedule: nil,
              next_daily_article_at: nil,
              _rev: nil,
              _id: nil

    def init(user_id) do
      case get_user_doc(user_id) do
        {:ok, nil} ->
          %__MODULE__{user_id: user_id}

        {:ok, %__MODULE__{} = state} ->
          state
      end
    end

    def save(state) do
      put_user_doc(state.user_id, state)
      state
    end

    def put_message(state, %Message{message_id: id} = msg) do
      messages_cache = state.messages_cache

      case messages_cache do
        [] ->
          %{state | messages_cache: [msg]}

        [%Message{message_id: id2} | _rest] ->
          if id == id2,
            do: state,
            else: %{state | messages_cache: [msg | messages_cache] |> Enum.take(50)}
      end
    end

    def get_cached_article(state) do
      %{getpocket_access_token: access_token, getpocket_articles_cache: cache} = state

      case cache do
        [article | rest_articles] ->
          {:ok, article, %{state | getpocket_articles_cache: rest_articles}}

        [] ->
          Logger.debug("Getting getpocket articles")

          with {:ok, list} <- getpocket().get_articles(access_token, count: 1000) do
            case Enum.shuffle(list) |> Enum.take(100) do
              [] ->
                {:ok, nil, %{state | getpocket_articles_cache: []}}

              [article | rest_articles] ->
                {:ok, article, %{state | getpocket_articles_cache: rest_articles}}
            end
          end
      end
    end

    defp get_user_doc(user_id) when not is_nil(user_id) do
      id = user_key(user_id)

      case couchdb().get_document(id) do
        {:ok, %Response{status_code: 200, body: body}} ->
          {:ok,
           Poison.decode!(
             body,
             as: %__MODULE__{
               messages_cache: [%Message{}],
               getpocket_articles_cache: [%Article{}]
             }
           )}

        {:ok, %Response{status_code: 404}} ->
          {:ok, nil}

        {:ok, resp} ->
          Logger.warn("Unexpected couchdb response #{inspect(resp)}")
          {:error, {:bad_response, resp}}

        {:error, error} ->
          {:error, {:http_error, error}}
      end
    end

    defp put_user_doc(user_id, %__MODULE__{} = doc) when is_integer(user_id) do
      id = user_key(user_id)

      case couchdb().put_document(id, doc._rev, doc) do
        {:ok, %Response{status_code: code, body: body}} when code in [201, 202] ->
          Logger.debug(fn -> "Saved user doc #{user_id}" end)
          {:ok, Poison.decode!(body, as: %__MODULE__{})}

        {:ok, %Response{} = resp} ->
          {:error, {:bad_response, resp}}
      end
    end

    defp couchdb, do: Application.get_env(:tggp, :bot_couchdb_impl)
    defp getpocket, do: Application.get_env(:tggp, :getpocket_impl)
    defp user_key(user_id), do: "user_state_" <> to_string(user_id)
  end

  def child_spec({:user_id, user_id}) do
    %{
      id: "USER.#{user_id}",
      start: {__MODULE__, :start_link, [user_id: user_id]},
      type: :worker,
      restart: :temporary
    }
  end

  def start_link({:user_id, user_id}) do
    GenServer.start_link(__MODULE__, user_id, name: process_name(user_id))
  end

  def dispatch(%Update{message: msg}) when is_map(msg) do
    %User{id: id} = msg.from
    pid = ensure_started!(id)
    GenServer.cast(pid, {:dispatch_message, msg})
  end

  def dispatch(%Update{channel_post: msg}) when is_map(msg) do
    Logger.warn("Dismissing message: #{inspect(msg)}")
  end

  def auth_done(user_id) do
    pid = ensure_started!(user_id)
    GenServer.call(pid, :auth_done)
  end

  def init(user_id) do
    Logger.info("Starting user #{user_id}")
    schedule_next_articles_check()
    {:ok, State.init(user_id)}
  end

  # Calls

  def handle_call(:auth_done, _from, state) do
    case state.getpocket_request_token do
      nil ->
        {:reply, {:error, :request_token_empty}, state}

      rt ->
        chat_id = state.chat_id

        new_state =
          case getpocket().get_access_token(rt) do
            {:ok, %{"access_token" => at}} ->
              telegram().send_message(chat_id, dgettext("server", "got getpocket access key"))

              %{state | getpocket_access_token: at}
              |> State.save()

            {:error, reason} ->
              Logger.warn("Can't get access token: #{inspect(reason)}")

              telegram().send_message(
                chat_id,
                dgettext("server", "failed to get getpocket access key")
              )

              state
          end

        {:reply, :ok, new_state}
    end
  end

  # Casts

  def handle_cast({:dispatch_message, %Message{text: text, chat: chat} = msg}, state) do
    new_state =
      case parse_command(text) do
        cmd when is_binary(cmd) ->
          %{state | chat_id: chat.id}
          |> State.put_message(msg)
          |> handle_command(cmd, msg)

        _ ->
          state
      end

    {:noreply, new_state}
  end

  # Info

  def handle_info(:check_daily_article, state) do
    new_state =
      case {state.daily_article_schedule, state.next_daily_article_at} do
        {nil, _} ->
          state

        {_, nil} ->
          state

        {time, datetime} ->
          if Timex.after?(Timex.now(), datetime) do
            try_send_article(state)
            |> Map.put(:next_daily_article_at, time_to_next_day(time))
            |> State.save()
          else
            state
          end
      end

    {:noreply, new_state}
  end

  defp try_send_article(%{chat_id: chat_id} = state) do
    case State.get_cached_article(state) do
      {:ok, nil, new_state} ->
        new_state

      {:ok, article, new_state} ->
        telegram().send_message(
          chat_id,
          "#{article.title}\n#{Article.getpocket_url(article)}"
        )

        new_state

      _ ->
        state
    end
  end

  # Commands

  def handle_command(state, "/start", %Message{chat: chat, from: user}) do
    case state.getpocket_access_token do
      access_token when is_binary(access_token) ->
        telegram().send_message(
          chat.id,
          dgettext("server", "already have getpocket access key")
        )

      _ ->
        telegram().send_message(
          chat.id,
          dgettext("server", "connecting getpocket and sending auth link for you")
        )

        redirect_uri = getpocket_url(TggpWeb.Endpoint, :auth_done, user.id)

        case getpocket().get_request_token(redirect_uri) do
          {:ok, request_token} ->
            link = getpocket().get_authorization_url(request_token, redirect_uri)

            telegram().send_message(
              chat.id,
              dgettext("server", "here is your link %{link}", link: link)
            )

            %{state | getpocket_request_token: request_token}

          {:error, reason} ->
            Logger.error("Failed to obtain request token: #{reason}")

            telegram().send_message(
              chat.id,
              dgettext("server", "something went wrong, try again")
            )

            state
        end
    end
  end

  def handle_command(state, "/rand", %Message{chat: chat, from: _user}) do
    case state.getpocket_access_token do
      nil ->
        telegram().send_message(
          chat.id,
          dgettext("server", "can't get article while not linked")
        )

        state

      _ ->
        case State.get_cached_article(state) do
          {:ok, nil, state} ->
            telegram().send_message(
              chat.id,
              dgettext("server", "seems like you didn't add any article to getpocket")
            )

            state

          {:ok, article, state} ->
            telegram().send_message(
              chat.id,
              "#{article.title}\n#{Article.getpocket_url(article)}"
            )

            state |> State.save()

          {:error, _} ->
            telegram().send_message(
              chat.id,
              dgettext("server", "failed to get article, try again")
            )

            state
        end
    end
  end

  def handle_command(state, "/daily", %Message{chat: chat, text: text}) do
    case state.getpocket_access_token do
      nil ->
        telegram().send_message(
          chat.id,
          dgettext("server", "cant subscribe while didnt link getpocket")
        )

        state

      _ ->
        case parse_time(text) do
          {:ok, %{hour: h, minute: m}} ->
            time = %Time{hour: h, minute: m, second: 0}

            datetime = time_to_next_day(time)

            state
            |> Map.put(:daily_article_schedule, time)
            |> Map.put(:next_daily_article_at, datetime)
            |> State.save()

          {:error, _} ->
            telegram().send_message(
              chat.id,
              dgettext("server", "wrong time string")
            )

            state
        end
    end
  end

  def handle_command(state, cmd, _msg) do
    Logger.warn("Unhandled command: #{inspect(cmd)}")
    state
  end

  # Utils
  defp parse_time(text) do
    case String.split(text, " ") do
      [_cmd, time_spec | _rest] ->
        Timex.parse(time_spec, "{h24}:{m}")

      _ ->
        {:error, :bad_format}
    end
  end

  defp parse_command(nil), do: nil

  defp parse_command(text) do
    case Regex.run(~r/^\/\w+/, text) do
      [cmd | _] ->
        cmd

      _ ->
        nil
    end
  end

  def ensure_started!(user_id) do
    case UserSupervisor.start_user(user_id) do
      {:ok, pid} ->
        pid

      {:error, {:already_started, pid}} ->
        pid
    end
  end

  defp time_to_next_day(%Time{} = t) do
    Timex.now()
    |> Timex.shift(days: 1)
    |> DateTime.truncate(:second)
    |> Map.merge(Map.take(t, [:hour, :minute]))
  end

  def schedule_next_articles_check do
    Logger.debug("Scheduling next articles check")
    Process.send_after(self(), :check_daily_article, @daily_articles_check_period_ms)
  end

  def process_name(user_id), do: {:via, Registry, {UsersRegistry, process_key(user_id)}}

  def process_key(user_id), do: {:user, user_id}

  def telegram, do: Application.get_env(:tggp, :telegram_impl)
  def getpocket, do: Application.get_env(:tggp, :getpocket_impl)
end
