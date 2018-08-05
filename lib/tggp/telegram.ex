defmodule Tggp.Telegram do
  alias Nadia.Model.{Message,Error, Update}

  @callback send_message(chat_id :: integer(), message :: binary()) :: {:ok, Message.t()} | {:error, Error.t()}

  @callback get_updates(offset :: integer()) :: {:ok, Update.t()} | {:error, Error.t()}
end

defmodule Tggp.Telegram.Impl do
  alias Nadia.Model.{Message, Error, Update}
  @poll_timeout 120
  @behaviour Tggp.Telegram

  @impl true
  def send_message(chat_id, message) do
    Nadia.send_message(chat_id, message)
  end

  @impl true
  def get_updates(offset \\ 0) do
    Nadia.get_updates(offset: offset, timeout: @poll_timeout)
  end
end
