defmodule Tggp.Bot.Couchdb do
  @callback get_document(id :: binary()) ::
              {:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}
  @callback put_document(id :: binary, rev :: binary(), data :: map()) ::
              {:ok, HTTPoison.Response.t()} | {:error, HTTPoison.Error.t()}
  # @callback user_key(user_id :: integer()) :: binary()
end

defmodule Tggp.Bot.Couchdb.Impl do
  use HTTPoison.Base
  @behaviour Tggp.Bot.Couchdb

  @impl true
  def get_document(id) do
    get("/#{id}")
  end

  @impl true
  def put_document(id, rev \\ nil, data) when is_map(data) do
    with {:ok, body} <- Poison.encode(data) do
      put_document(id, rev, body)
    end
  end

  def put_document(id, rev, body) when is_binary(body) do
    url = if rev, do: "/#{id}?rev=#{rev}", else: "/#{id}"
    put(url, body)
  end

  def find_documents(query) when is_map(query) do
    with {:ok, body} <- Poison.encode(query) do
      post("/_find", body)
    end
  end

  # @impl true
  # def user_key(user_id) do
  #   "user_state_#{user_id}"
  # end

  def process_url(url) do
    db_url() <> url
  end

  defp process_request_options(opts) do
    Keyword.update(
      opts,
      :hackney,
      [basic_auth: {username(), user_password()}],
      &Keyword.put(&1, :basic_auth, {username(), user_password()})
    )
  end

  defp db_url, do: "https://i2.mluts.net/tggp"
  defp username, do: "elixir_app"
  defp user_password, do: "DkTmQrtPdrv8"
end
