defmodule Getpocket.Api.GetRequest do
  @sort_newest "newest"
  # @sort_oldest "sort_oldest"

  defstruct access_token: nil, consumer_key: nil, count: 10, offset: 0, sort: @sort_newest
end

defmodule Getpocket.Api.ArchiveRequest do
  defstruct item_id: nil
end

defmodule Getpocket.Api.Article do
  defstruct id: nil, title: nil, given_url: nil, raw: %{}

  def from_map(map) when is_map(map) do
    %__MODULE__{
      id: map["item_id"],
      title: map["excerpt"],
      given_url: map["giten_url"],
      raw: map
    }
  end

  def getpocket_url(%__MODULE__{id: id}) do
    "https://getpocket.com/a/read/#{id}"
  end
end

defmodule Getpocket.Api do
  @base_uri URI.parse("https://getpocket.com")
  @json_headers [{"content-type", "application/json; charset=UTF-8"},
                 {"x-accept", "application/json"}]

  @type article :: %__MODULE__.Article{}

  def get_articles(consumer_key, access_token, opts \\ []) do
    count = Keyword.get(opts, :count, 10)
    offset = Keyword.get(opts, :offset, 0)

    payload = %__MODULE__.GetRequest{
      consumer_key: consumer_key,
      access_token: access_token,
      count: count,
      offset: offset
    } |> Poison.encode!

    case HTTPoison.post( %{ @base_uri | path: "/v3/get" }, payload, @json_headers) do
      {:ok, %HTTPoison.Response{status_code: 200, body: body}} ->
        case body |> Poison.decode do
          {:ok, %{"list" => articles}} ->
            Map.values(articles) |> Enum.map(&Getpocket.Api.Article.from_map/1)
          {:error, reason} ->
            {:error, inspect(reason)}
        end
    end
  end

  def archive(consumer_key, access_token, %__MODULE__.Article{id: id}) do
    payload = %{
      actions: [%{
        action: "archive",
        item_id: to_string(id)
      }],

      consumer_key: consumer_key,
      access_token: access_token
    } |> Poison.encode!

    url = %{ @base_uri | path: "/v3/send"}

    {:ok, %HTTPoison.Response{status_code: 200}} =
      HTTPoison.post(url, payload, @json_headers)
    :ok
  end
end
