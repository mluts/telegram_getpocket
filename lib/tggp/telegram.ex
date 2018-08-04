defmodule Tggp.Telegram do
  alias Nadia.Model.{Message,Error}

  @callback send_message(chat_id :: integer(), message :: binary()) :: {:ok, Message.t()} | {:error, Error.t()}
end

defmodule Tggp.Telegram.Impl do
  @behaviour Tggp.Telegram

  @impl true
  def send_message(chat_id, message) do
    Nadia.send_message(chat_id, message)
  end
end
