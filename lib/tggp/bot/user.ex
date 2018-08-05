defmodule Tggp.Bot.User do
  use GenServer
  require Logger
  import Tggp.Gettext
  import TggpWeb.Router.Helpers

  alias Tggp.Bot.{UsersRegistry, UserSupervisor}
  alias Nadia.Model.{User, Message, Update}
  alias HTTPoison.Response

  defmodule State do
    @derive {Poison.Encoder, except: ~w(_rev _id)a}

    defstruct user_id: nil,
              chat_id: nil,
              getpocket_access_token: nil,
              getpocket_request_token: nil,
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

    def get_chat_id(state), do: state.chat_id
    def put_chat_id(state, chat_id), do: %{state | chat_id: chat_id}

    def get_getpocket_access_token(%__MODULE__{getpocket_access_token: at}), do: at

    def put_getpocket_access_token(state, access_token) do
      Map.put(state, :getpocket_access_token, access_token)
    end

    def get_getpocket_request_token(%__MODULE__{getpocket_request_token: rt}), do: rt

    def put_getpocket_request_token(state, request_token) do
      Map.put(state, :getpocket_request_token, request_token)
    end

    defp get_user_doc(user_id) when not is_nil(user_id) do
      id = user_key(user_id)

      case couchdb().get_document(id) do
        {:ok, %Response{status_code: 200, body: body}} ->
          {:ok, Poison.decode!(body, as: %__MODULE__{})}

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
          {:ok, Poison.decode!(body, as: %__MODULE__{})}

        {:ok, %Response{} = resp} ->
          {:error, {:bad_response, resp}}
      end
    end

    defp couchdb, do: Application.get_env(:tggp, :bot_couchdb_impl)
    defp user_key(user_id), do: "user_state_#{user_id}"
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
    GenServer.start_link(__MODULE__, [user_id], name: process_name(user_id))
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
    {:ok, State.init(user_id)}
  end

  # Calls

  def handle_call(:auth_done, _from, state) do
    case State.get_getpocket_request_token(state) do
      nil ->
        {:reply, {:error, :request_token_empty}, state}

      rt ->
        chat_id = State.get_chat_id(state)

        new_state =
          case getpocket().get_access_token(rt) do
            {:ok, %{"access_token" => at}} ->
              telegram().send_message(chat_id, dgettext("server", "got getpocket access key"))
              State.put_getpocket_access_token(state, at)

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
          state
          |> State.put_chat_id(chat.id)
          |> handle_command(cmd, msg)

        _ ->
          state
      end

    {:noreply, new_state}
  end

  # Commands

  def handle_command(state, "/start", %Message{chat: chat, from: user}) do
    case State.get_getpocket_access_token(state) do
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

            State.put_getpocket_request_token(state, request_token)

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

  # Utils

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

  def process_name(user_id) do
    {:via, Registry, {UsersRegistry, {:user, user_id}}}
  end

  def telegram, do: Application.get_env(:tggp, :telegram_impl)
  def getpocket, do: Application.get_env(:tggp, :getpocket_impl)
end
