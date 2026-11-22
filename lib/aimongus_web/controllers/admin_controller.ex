defmodule AimongusWeb.AdminController do
  @moduledoc """
  Operator controls. The only endpoint is `POST /admin/new-match`, which
  asks the MatchManager to tear down the current match and immediately
  start the next one (skipping the inter-match pause).

  Gated by the `AIMONGUS_ADMIN_TOKEN` env var: callers pass it as the
  `token` param or the `x-admin-token` header. With the env var unset
  everything is denied — an unconfigured deploy can't accidentally leave
  match control open to visitors.
  """

  use AimongusWeb, :controller

  alias Aimongus.Match.Manager
  alias AimongusWeb.AdminAuth

  def new_match(conn, params) do
    given = params["token"] || header_token(conn)

    case AdminAuth.authorize(given) do
      :disabled ->
        conn |> put_status(:forbidden) |> json(%{error: "admin disabled"})

      :unauthorized ->
        conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})

      :ok ->
        if Process.whereis(Manager) == nil do
          conn |> put_status(:service_unavailable) |> json(%{error: "match manager not running"})
        else
          :ok = Manager.new_match()
          conn |> put_status(:accepted) |> json(%{status: "restarting match"})
        end
    end
  end

  defp header_token(conn) do
    case get_req_header(conn, "x-admin-token") do
      [token | _rest] -> token
      [] -> nil
    end
  end
end
