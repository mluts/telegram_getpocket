defmodule Tggp.Getpocket do
  def get_request_token(redirect_uri) do
    Getpocket.Auth.get_request_token(consumer_key(), redirect_uri)
  end

  def get_authorization_url(request_token, redirect_uri) do
    Getpocket.Auth.build_authorization_url(request_token, redirect_uri)
  end

  def get_access_token(request_token) do
    Getpocket.Auth.get_access_token(consumer_key(), request_token)
  end

  def get_articles(access_token, opts \\ []),
    do: Getpocket.Api.get_articles(consumer_key(), access_token, opts)

  def archive(access_token, %Getpocket.Api.Article{} = a),
    do: Getpocket.Api.archive(consumer_key(), access_token, a)

  defp consumer_key, do: Application.get_env(:tggp, Tggp.Getpocket)[:consumer_key]
end
