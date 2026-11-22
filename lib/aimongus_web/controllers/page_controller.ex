defmodule AimongusWeb.PageController do
  use AimongusWeb, :controller

  def home(conn, _params) do
    render(conn, :home)
  end
end
