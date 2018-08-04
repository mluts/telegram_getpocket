defmodule Tggp.Getpocket do
  @callback get_request_token(redirect_uri :: binary()) :: {:ok, request_token :: binary()} | {:error, any()}

  @callback get_authorization_url(request_token :: binary(), redirect_uri :: binary()) :: URI.t()

  @callback get_access_token(request_token :: binary()) :: {:ok, access_token :: binary()} | {:error, any()}

  @callback get_articles(access_token :: binary(), opts :: keyword())  :: {:ok, [Getpocket.Api.article()]} | {:error, any()}

  @callback archive(access_token ::binary, Getpocket.Api.article()) :: :ok
end

defmodule Tggp.Getpocket.Impl do
  @behaviour Tggp.Getpocket

  @impl true
  def get_request_token(redirect_uri) do
    Getpocket.Auth.get_request_token(consumer_key(), redirect_uri)
  end

  @impl true
  def get_authorization_url(request_token, redirect_uri) do
    Getpocket.Auth.build_authorization_url(request_token, redirect_uri)
  end

  @impl true
  def get_access_token(request_token) do
    Getpocket.Auth.get_access_token(consumer_key(), request_token)
  end

  @impl true
  def get_articles(access_token, opts \\ []),
    do: Getpocket.Api.get_articles(consumer_key(), access_token, opts)

  @impl true
  def archive(access_token, %Getpocket.Api.Article{} = a),
    do: Getpocket.Api.archive(consumer_key(), access_token, a)

  defp consumer_key, do: Application.get_env(:tggp, Tggp.Getpocket)[:consumer_key]
end
