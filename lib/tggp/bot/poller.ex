defmodule Tggp.Bot.Poller do
  @command_regex ~r/^\/\w+/
  @poll_timeout 120 # Seconds

  require Logger
  alias Nadia.Model.{Update, Message, Error}

  def child_spec(_args) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, []},
      type: :worker
    }
  end

  def start_link do
    pid = spawn_link(fn -> loop() end)
    {:ok, pid}
  end

  defp loop(offset \\ 0) do
    case Nadia.get_updates(offset: offset, timeout: @poll_timeout) do
      {:ok, updates} -> 
        # Logger.debug(fn ->
        #   "Having #{Enum.count(updates)} updates!"
        # end)
        ids = for %Update{update_id: id} = update <- updates do
          handle_update(update)
          id
        end
        loop(Enum.max(ids, fn -> 0 end) + 1)

      {:error, %Error{} = err} ->
        Logger.error("Failed to get telegram updates: #{Error.message(err)}")
        loop(offset)
    end
  end

  defp handle_update(%Update{message: message} = update) do
    handle_message(message)
  end

  def handle_message(%Message{chat: chat, from: user, text: text} = message) do
    case message_command(message) do
      nil ->
        handle_text(text, message)
      cmd ->
        handle_command(cmd, message)
    end
  end

  defp message_command(%Message{text: text} = message) do
    case Regex.run(@command_regex, text) do
      [cmd | _] ->
        cmd
      _ ->
        nil
    end
  end

  def handle_command(cmd, %Message{} = msg) do
    :ok = GenServer.cast(Tggp.Bot.Server, {:command, cmd, msg})
  end

  def handle_text(cmd, %Message{} = msg) do
    :ok = GenServer.cast(Tggp.Bot.Server, {:text, cmd, msg})
  end
end
