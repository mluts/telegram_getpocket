defmodule Tggp.Getpocket do
  @getpocket_opts Application.get_env(:tggp, Tggp.Getpocket)
  @consumer_key Keyword.get(@getpocket_opts, :consumer_key)

  def get_request_token(redirect_uri) do
    Getpocket.Auth.get_request_token(@consumer_key, redirect_uri)
  end

  def get_authorization_url(request_token, redirect_uri) do
    Getpocket.Auth.build_authorization_url(request_token, redirect_uri)
  end

  def get_access_token(request_token) do
    Getpocket.Auth.get_access_token(@consumer_key, request_token)
  end

  def get_articles(access_token, opts \\ []),
    do: Getpocket.Api.get_articles(@consumer_key, access_token, opts)
end
