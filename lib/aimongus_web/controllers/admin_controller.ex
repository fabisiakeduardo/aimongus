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

  def new_match(conn, params) do
    expected = System.get_env("AIMONGUS_ADMIN_TOKEN")
    given = params["token"] || header_token(conn)

    cond do
      is_nil(expected) or expected == "" ->
        conn |> put_status(:forbidden) |> json(%{error: "admin disabled"})

      not valid_token?(given, expected) ->
        conn |> put_status(:unauthorized) |> json(%{error: "unauthorized"})

      Process.whereis(Manager) == nil ->
        conn |> put_status(:service_unavailable) |> json(%{error: "match manager not running"})

      true ->
        :ok = Manager.new_match()
        conn |> put_status(:accepted) |> json(%{status: "restarting match"})
    end
  end

  defp header_token(conn) do
    case get_req_header(conn, "x-admin-token") do
      [token | _rest] -> token
      [] -> nil
    end
  end

  # constant-time compare keeps the token's value out of timing attacks;
  # secure_compare/2 already returns false on a length mismatch
  defp valid_token?(given, expected) when is_binary(given) do
    Plug.Crypto.secure_compare(given, expected)
  end

  defp valid_token?(_given, _expected), do: false
end
