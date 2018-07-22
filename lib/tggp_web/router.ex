defmodule TggpWeb.Router do
  use TggpWeb, :router

  pipeline :browser do
    plug :accepts, ["html"]
    plug :fetch_session
    plug :fetch_flash
    plug :protect_from_forgery
    plug :put_secure_browser_headers
  end

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", TggpWeb do
    pipe_through :browser # Use the default browser stack

    get "/", PageController, :index
    get "/getpocket/:user_id/auth_done", GetpocketController, :auth_done
  end

  # Other scopes may use custom stacks.
  # scope "/api", TggpWeb do
  #   pipe_through :api
  # end
end
