defmodule Tggp.Bot.Server do
  @dump_period_ms 5 * 60 * 1000
  @cache_purge_period_ms @dump_period_ms

  require Logger

  alias Nadia.Model.{Message, Chat, User}
  alias Getpocket.Api.Article
  alias Tggp.Getpocket, as: GP

  use GenServer
  import TggpWeb.Router.Helpers

  defmodule Getpocket do
    defstruct request_token: nil, redirect_uri: nil, access_token: nil
  end

  defmodule State do
    @cache_ttl_ms 30 * 60 * 1000

    def dump_path, do:
    Path.join(:code.priv_dir(:tggp), "bot_server_state.ets") |> String.to_charlist

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

    def put_user(table, %User{id: id} = user), do:
    :ets.insert(table, {{id, :user}, user})

    def put_getpocket(table, user_id, %Getpocket{} = gp), do:
    :ets.insert(table, {{user_id, :getpocket}, gp})

    def put_chat(table, user_id, %Chat{} = chat), do:
    :ets.insert(table, {{user_id, :chat}, chat})

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

    def cached(table, cache_name, cached_fn) when is_atom(cache_name) and is_function(cached_fn, 0) do
      stale_cache_time = time_ms() - @cache_ttl_ms

      ms = {
        {{:"$1", :cache, cache_name}, :"$2"},
        [{:is_integer, :"$1"}, {:>, :"$1", stale_cache_time}],
        [{{:ok, :"$2"}}]
      }

      case :ets.select(table, [ms]) do
        [{:ok, content} ] ->
          content
        [] ->
          content = cached_fn.()
          :ets.insert(table, {{time_ms(), :cache, cache_name}, content})
          content
      end
    end

    def purge_cache(table) do
      stale_cache_time = time_ms() - @cache_ttl_ms

      ms = {
        {{:"$1", :cache, :"$_"}, :"$_"},
        [{:is_integer, :"$1"},
         {:<, :"$1", stale_cache_time}],
        [true]
      }

      :ets.select_delete(table, [ms])
    end

    defp time_ms, do: System.system_time(:millisecond)
  end

  def init(_args) do
    Logger.info "Starting #{__MODULE__}"
    schedule_dump()
    schedule_purge_cache()
    {:ok, %{table: State.init}}
  end

  def start_link([]) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def handle_call({:auth_done, user_id}, _from, %{table: t} = state) when is_integer(user_id) do
    %Chat{} = chat = State.get_chat(t, user_id)
    %Getpocket{request_token: rt} = State.get_getpocket(t, user_id)

    case GP.get_access_token(rt) do
      {:ok, %{"access_token" => at}} ->
        Nadia.send_message(chat.id, "Yass. I'm in, now linked getpocket!")
        State.put_getpocket(t, user_id, %Getpocket{access_token: at})

      {:error, reason} ->
        Logger.warn("Can't get access token: #{inspect(reason)}")
        Nadia.send_message(chat.id, "Can't get access token :( Lets try again")
    end

    {:reply, :ok, state}
  end

  def handle_cast({:command, "/start", %Message{chat: chat, from: user}}, %{table: t} = state) do
    case State.get_getpocket(t, user.id) do
      %Getpocket{access_token: token} when is_binary(token) ->
        Nadia.send_message(
          chat.id,
          "Already connected your getpocket. Want some article?"
        )

        State.put_user(t, user)
        State.put_chat(t, user.id, chat)

      _ ->
        Nadia.send_message(
          chat.id,
          "Hi, i'm not connected to your getpocket account, so let's do it. Preparing a link for you"
        )

        redirect_uri = getpocket_url(TggpWeb.Endpoint, :auth_done, user.id)

        getpocket = case GP.get_request_token(redirect_uri) do
          {:ok, request_token} ->
            link = GP.get_authorization_url(request_token, redirect_uri)
            Nadia.send_message(chat.id, "Here is your link: #{link}")
            %Getpocket{request_token: request_token, redirect_uri: redirect_uri}
          {:error, reason} ->
            Logger.error("Failed to obtain request token: #{reason}")
            Nadia.send_message(chat.id, "Something went wrong :( lets try again")
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
      %Getpocket{access_token: at} ->
        article = State.cached(t, :articles_for_rand, fn ->
          GP.get_articles(at, count: 2000)
        end)
        |> Enum.random

        Nadia.send_message(
          chat.id,
          "#{article.title}\n#{Article.getpocket_url(article)}"
        )
      _ -> nil
    end

    {:noreply, state}
  end

  def handle_cast(req, _state) do
    Logger.debug(fn ->
      "Unknown message: #{inspect(req)}"
    end)
  end

  def handle_info(:dump, %{table: t} = state) do
    Logger.info "Dump ets database"
    State.dump(t)
    schedule_dump()
    {:noreply, state}
  end

  def handle_info(:purge_cache, %{table: t} = state) do
    Logger.info "Purge cache"
    State.purge_cache(t)
    schedule_purge_cache()
    {:noreply, state}
  end

  def schedule_dump do
    Logger.debug "Scheduling bot-server ets dump"
    Process.send_after(self(), :dump, @dump_period_ms)
  end

  def schedule_purge_cache do
    Logger.debug "Scheduling bot-server cache purge"
    Process.send_after(self(), :purge_cache, @cache_purge_period_ms)
  end
end
