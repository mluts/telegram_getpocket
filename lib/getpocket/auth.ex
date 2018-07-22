defmodule Getpocket.Auth do
  @moduledoc """
    Getpocket authentication module
  """

  @base_uri URI.parse("https://getpocket.com")
  @request_token_uri %{ @base_uri | path: "/v3/oauth/request" }
  @authorize_uri_base %{ @base_uri | path: "/auth/authorize" }
  @access_token_uri %{ @base_uri | path: "/v3/oauth/authorize" }

  @json_headers [{"content-type", "application/json; charset=UTF-8"},
                 {"x-accept", "application/json"}]

  def get_request_token(consumer_key, redirect_uri) do
    payload = Poison.encode!(%{
      consumer_key: consumer_key,
      redirect_uri: redirect_uri
    })

    case HTTPoison.post(@request_token_uri, payload, @json_headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        decode_request_token(body)
      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, "Status code: #{code}"}
      {:error, reason} ->
        {:error, reason}
    end
  end

  def build_authorization_url(request_token, redirect_uri) do
    query = URI.encode_query(%{
      request_token: request_token,
      redirect_uri: redirect_uri
    })

    %{ @authorize_uri_base | query: query }
  end

  def get_access_token(consumer_key, request_token) do
    payload = Poison.encode!(%{
      consumer_key: consumer_key,
      code: request_token
    })

    case HTTPoison.post(@access_token_uri, payload, @json_headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        decode_access_token(body)
      {:ok, %HTTPoison.Response{status_code: code}} ->
        {:error, "Status code: #{code}"}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp decode_request_token(body) do
    case body |> Poison.decode do
      {:ok, %{"code" => request_token}} ->
        {:ok, request_token}
      _ ->
        {:error, "Failed to decode \"code\" from #{body}"}
    end
  end

  defp decode_access_token(body) do
    case body |> Poison.decode do
      {:ok, %{"access_token" => _}} = result ->
        result
      _ ->
        {:error, "Failed to decode \"access_token\" from #{body}"}
    end
  end
end
