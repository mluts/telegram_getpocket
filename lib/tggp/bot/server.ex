defmodule Tggp.Bot.Server do
  @dump_period_ms 5 * 60 * 1000
  @cache_purge_period_ms @dump_period_ms
  @check_subscriptions_period_ms 60 * 1000

  require Logger

  alias Nadia.Model.{Message, Chat, User}
  alias Getpocket.Api.Article
  alias Tggp.Getpocket, as: GP

  import TggpWeb.Router.Helpers
  require Tggp.Gettext
  import Tggp.Gettext

  use GenServer

  defmodule Getpocket do
    defstruct request_token: nil, redirect_uri: nil, access_token: nil
  end

  defmodule State do
    @cache_ttl_ms 30 * 60 * 1000

    def dump_path,
      do: Path.join(:code.priv_dir(:tggp), "bot_server_state.ets") |> String.to_charlist()

    def init do
      case :ets.file2tab(dump_path()) do
        {:ok, table} ->
          table

        {:error, {:read_error, {:file_error, _, :enoent}}} ->
          :ets.new(:bot_server_state, [:private])
      end
    end

    def dump(table) do
      :ok = :ets.tab2file(table, dump_path())
    end

    def put_user(table, %User{id: id} = user), do: :ets.insert(table, {{id, :user}, user})

    def put_getpocket(table, user_id, %Getpocket{} = gp),
      do: :ets.insert(table, {{user_id, :getpocket}, gp})

    def put_chat(table, user_id, %Chat{} = chat), do: :ets.insert(table, {{user_id, :chat}, chat})

    def get_user(table, id) do
      case :ets.lookup(table, {id, :user}) do
        [{_key, entry}] -> entry
        [] -> nil
      end
    end

    def get_getpocket(table, id) do
      case :ets.lookup(table, {id, :getpocket}) do
        [{_key, entry}] -> entry
        [] -> nil
      end
    end

    def get_chat(table, id) do
      case :ets.lookup(table, {id, :chat}) do
        [{_key, entry}] -> entry
        [] -> nil
      end
    end

    def schedule_user_event(table, user_id, key, future_time) do
      :ets.insert(table, {{user_id, :schedule, key}, future_time})
    end

    def get_scheduled_user_events(table) do
      ms = {
        {{:"$1", :schedule, :"$2"}, :"$3"},
        [],
        [{{:"$1", :"$2", :"$3"}}]
      }

      :ets.select(table, [ms])
    end

    def delete_schedule(table, user_id, key) do
      :ets.delete(table, {user_id, :schedule, key})
    end

    def delete_user_schedules(table, user_id) do
      ms = {
        {{user_id, :schedule, :"$_"}, :"$_"},
        [],
        [true]
      }

      :ets.select_delete(table, [ms])
    end

    def cached(table, key, cached_fn) when is_binary(key) and is_function(cached_fn, 0) do
      stale_cache_time = time_ms() - @cache_ttl_ms

      ms = {
        {{:"$1", :cache, key}, :"$2"},
        [{:is_integer, :"$1"}, {:>, :"$1", stale_cache_time}],
        [{{:ok, :"$2"}}]
      }

      case :ets.select(table, [ms]) do
        [{:ok, content}] ->
          content

        [] ->
          content = cached_fn.()
          :ets.insert(table, {{time_ms(), :cache, key}, content})
          content
      end
    end

    def purge_cache(table) do
      stale_cache_time = time_ms() - @cache_ttl_ms

      ms = {
        {{:"$1", :cache, :"$_"}, :"$_"},
        [{:is_integer, :"$1"}, {:<, :"$1", stale_cache_time}],
        [true]
      }

      :ets.select_delete(table, [ms])
    end

    def update_user_state(table, user_id, map) when is_map(map) do
      state = get_user_state(table, user_id)
      new_state = Map.merge(state, map)
      :ets.insert(table, {{user_id, :state}, new_state})
    end

    def get_user_state(table, user_id) do
      case :ets.lookup(table, {user_id, :state}) do
        [{_key, state}] -> state
        [] -> %{}
      end
    end

    defp time_ms, do: System.system_time(:millisecond)
  end

  def telegram, do: Application.get_env(:tggp, :telegram_impl)
  def getpocket, do: Application.get_env(:tggp, :getpocket_impl)

  def child_spec([]) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [[]]},
      type: :worker,
      shutdown: 5000
    }
  end

  def init(_args) do
    Process.flag(:trap_exit, true)
    Logger.info("Starting #{__MODULE__}")
    schedule_dump()
    schedule_purge_cache()
    schedule_check_subscriptions()
    {:ok, %{table: State.init()}}
  end

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def handle_call(:terminate, _from, state) do
    {:stop, :normal, :ok, state}
  end

  def handle_call({:auth_done, user_id}, _from, %{table: t} = state) when is_integer(user_id) do
    %Chat{} = chat = State.get_chat(t, user_id)
    %Getpocket{request_token: rt} = State.get_getpocket(t, user_id)

    case getpocket().get_access_token(rt) do
      {:ok, %{"access_token" => at}} ->
        telegram().send_message(chat.id, dgettext("server", "got getpocket access key"))
        State.put_getpocket(t, user_id, %Getpocket{access_token: at})

      {:error, reason} ->
        Logger.warn("Can't get access token: #{inspect(reason)}")
        telegram().send_message(chat.id, dgettext("server", "failed to get getpocket access key"))
    end

    {:reply, :ok, state}
  end

  def handle_cast({:command, "/start", %Message{chat: chat, from: user}}, %{table: t} = state) do
    case State.get_getpocket(t, user.id) do
      %Getpocket{access_token: token} when is_binary(token) ->
        telegram().send_message(
          chat.id,
          dgettext("server", "already have getpocket access key")
        )

        State.put_user(t, user)
        State.put_chat(t, user.id, chat)

      _ ->
        telegram().send_message(
          chat.id,
          dgettext("server", "connecting getpocket and sending auth link for you")
        )

        redirect_uri = getpocket_url(TggpWeb.Endpoint, :auth_done, user.id)

        getpocket =
          case getpocket().get_request_token(redirect_uri) do
            {:ok, request_token} ->
              link = getpocket().get_authorization_url(request_token, redirect_uri)

              telegram().send_message(
                chat.id,
                dgettext("server", "here is your link %{link}", link: link)
              )

              %Getpocket{request_token: request_token, redirect_uri: redirect_uri}

            {:error, reason} ->
              Logger.error("Failed to obtain request token: #{reason}")

              telegram().send_message(
                chat.id,
                dgettext("server", "something went wrong, try again")
              )

              nil
          end

        State.put_user(t, user)
        State.put_chat(t, user.id, chat)
        State.put_getpocket(t, user.id, getpocket)
    end

    {:noreply, state}
  end

  def handle_cast({:command, "/rand", %Message{chat: chat, from: user}}, %{table: t} = state) do
    case State.get_getpocket(t, user.id) do
      %Getpocket{access_token: at} when is_binary(at) ->
        case get_cached_article(user.id, t) do
          {:ok, _chat_id, article} ->
            State.update_user_state(t, user.id, %{
              last_article: article,
              last_article_at: in_user_timezone(user.id, Timex.now())
            })

            telegram().send_message(
              chat.id,
              "#{article.title}\n#{Article.getpocket_url(article)}"
            )

          {:error, _reason} ->
            telegram().send_message(
              chat.id,
              dgettext("server", "failed to get article, try again")
            )
        end

      _ ->
        telegram().send_message(
          chat.id,
          dgettext("server", "can't get article while not linked")
        )

        nil
    end

    {:noreply, state}
  end

  def handle_cast(
        {:command, "/daily" = cmd, %Message{chat: chat, from: user, text: text}},
        %{table: t} = state
      ) do
    case State.get_getpocket(t, user.id) do
      %Getpocket{access_token: at} when is_binary(at) ->
        case String.split(text, " ") do
          [^cmd, time | _] ->
            case Timex.parse(time, "{h24}:{m}") do
              {:ok, %{hour: h, minute: m, second: s}} ->
                now = in_user_timezone(user.id, Timex.now())
                today = %{now | hour: h, minute: m, second: s}
                tomorrow = Timex.shift(today, days: 1)
                winner_time = if today > now, do: today, else: tomorrow

                State.schedule_user_event(t, user.id, :daily_getpocket_random, winner_time)

                telegram().send_message(
                  chat.id,
                  dgettext("server", "ok, sending article every day at %{time}", time: time)
                )

              {:error, _reason} ->
                telegram().send_message(chat.id, dgettext("server", "wrong time string"))
            end

          _ ->
            telegram().send_message(chat.id, dgettext("server", "wrong time string"))
        end

      _ ->
        telegram().send_message(
          chat.id,
          dgettext("server", "cant subscribe while didnt link getpocket")
        )
    end

    {:noreply, state}
  end

  def handle_cast(
        {:command, "/unsubscribe", %Message{chat: chat, from: user}},
        %{table: t} = state
      ) do
    State.delete_user_schedules(t, user.id)
    telegram().send_message(chat.id, dgettext("server", "ok, unsubscribing"))
    {:noreply, state}
  end

  def handle_cast({:command, "/archive", %Message{chat: chat, from: user}}, %{table: t} = state) do
    case {State.get_getpocket(t, user.id), State.get_user_state(t, user.id)} do
      {%Getpocket{access_token: at}, %{last_article: article}}
      when is_binary(at) and is_map(article) ->
        :ok = getpocket().archive(at, article)
        telegram().send_message(chat.id, dgettext("server", "archived article"))

      res ->
        Logger.warn(inspect(res))
        telegram().send_message(chat.id, dgettext("server", "cant archive article"))
    end

    {:noreply, state}
  end

  def handle_cast({:schedule, user_id, :daily_getpocket_random = key, time}, %{table: t} = state) do
    now = in_user_timezone(user_id, Timex.now())

    if time < now do
      case get_cached_article(user_id, t) do
        {:error, _reason} ->
          State.delete_schedule(t, user_id, key)

        {:ok, chat_id, article} ->
          State.update_user_state(t, user_id, %{
            last_article: article,
            last_article_at: in_user_timezone(user_id, Timex.now())
          })

          telegram().send_message(
            chat_id,
            "#{article.title}\n#{Article.getpocket_url(article)}"
          )

          next_day = %{Timex.shift(now, days: 1) | hour: time.hour, minute: time.minute}
          State.schedule_user_event(t, user_id, key, next_day)
      end
    end

    {:noreply, state}
  end

  def handle_cast(req, state) do
    Logger.debug(fn ->
      "Unknown message: #{inspect(req)}"
    end)

    {:noreply, state}
  end

  def handle_info(:dump, %{table: t} = state) do
    Logger.info("Dump ets database")
    State.dump(t)
    schedule_dump()
    {:noreply, state}
  end

  def handle_info(:purge_cache, %{table: t} = state) do
    Logger.info("Purge cache")
    State.purge_cache(t)
    schedule_purge_cache()
    {:noreply, state}
  end

  def handle_info(:check_subscriptions, %{table: t} = state) do
    Logger.debug("Checking subscriptions")

    for {user_id, event_key, datetime} <- State.get_scheduled_user_events(t) do
      GenServer.cast(__MODULE__, {:schedule, user_id, event_key, datetime})
    end

    schedule_check_subscriptions()
    {:noreply, state}
  end

  def schedule_dump do
    Logger.debug("Scheduling bot-server ets dump")
    Process.send_after(self(), :dump, @dump_period_ms)
  end

  def schedule_purge_cache do
    Logger.debug("Scheduling bot-server cache purge")
    Process.send_after(self(), :purge_cache, @cache_purge_period_ms)
  end

  def schedule_check_subscriptions do
    Logger.debug("Scheduling subscriptions check")
    Process.send_after(self(), :check_subscriptions, @check_subscriptions_period_ms)
  end

  def terminate(_reason, %{table: t}) do
    Logger.info("Terminating...")
    Logger.info("Dump database before terminate")
    State.dump(t)
  end

  defp get_cached_article(user_id, table) do
    case State.get_chat(table, user_id) do
      nil ->
        {:error, :no_chat_found}

      %Chat{id: chat_id} ->
        case State.get_getpocket(table, user_id) do
          %Getpocket{access_token: at} ->
            article =
              State.cached(table, "articles_for_rand:#{user_id}", fn ->
                getpocket().get_articles(at, count: 2000)
              end)
              |> Enum.random()

            {:ok, chat_id, article}

          _ ->
            {:error, :no_getpocket_access_key}
        end
    end
  end

  defp in_user_timezone(_user_id, time) do
    tz = Timex.Timezone.local()
    Timex.Timezone.convert(time, tz)
  end
end
