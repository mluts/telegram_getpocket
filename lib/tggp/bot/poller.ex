defmodule Tggp.Bot.Poller do
  # @command_regex ~r/^\/\w+/
  # Seconds
  # @poll_timeout 120

  require Logger
  alias Nadia.Model.{Update, Error}

  def child_spec(update_handler) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, update_handler},
      restart: :permanent,
      type: :worker
    }
  end

  def start_link(update_handler) do
    case Nadia.Config.token() do
      nil ->
        {:error, :telegram_bot_token_empty}

      _ ->
        Logger.info "Starting bot poller"
        pid = spawn_link(fn -> loop(update_handler) end)
        {:ok, pid}
    end
  end

  defp loop(update_handler, offset \\ 0) when is_function(update_handler) do
    case telegram().get_updates(offset) do
      {:ok, updates} ->
        # Logger.debug(fn ->
        #   "Having #{Enum.count(updates)} updates!"
        # end)
        ids =
          for %Update{update_id: id} = update <- updates do
            update_handler.(update)
            id
          end

        loop(update_handler, Enum.max(ids, fn -> 0 end) + 1)

      {:error, %Error{} = err} ->
        msg = Error.message(err)
        Logger.error(msg)
        exit({:shutdown, msg})
    end
  end

  # defp handle_update(%Update{message: message}) do
  #   handle_message(message)
  # end

  # def handle_message(%Message{text: text} = message) do
  #   case message_command(message) do
  #     nil ->
  #       handle_text(text, message)

  #     cmd ->
  #       handle_command(cmd, message)
  #   end
  # end

  # def handle_message(nil), do: nil

  # defp message_command(%Message{text: text}) do
  #   case Regex.run(@command_regex, text) do
  #     [cmd | _] ->
  #       cmd

  #     _ ->
  #       nil
  #   end
  # end

  # def handle_command(cmd, %Message{} = msg) do
  #   :ok = GenServer.cast(Tggp.Bot.Server, {:command, cmd, msg})
  # end

  # def handle_text(cmd, %Message{} = msg) do
  #   :ok = GenServer.cast(Tggp.Bot.Server, {:text, cmd, msg})
  # end

  def telegram, do: Application.get_env(:tggp, :telegram_impl)
end
