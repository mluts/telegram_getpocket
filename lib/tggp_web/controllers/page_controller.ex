defmodule TggpWeb.PageController do
  use TggpWeb, :controller

  def index(conn, _params) do
    render conn, "index.html"
  end
end
