defmodule AimongusWeb.AdminControllerTest do
  # async: false — AIMONGUS_ADMIN_TOKEN is process-global env
  use AimongusWeb.ConnCase, async: false

  alias Aimongus.Match.Manager

  @token "test-admin-token"

  setup do
    previous = System.get_env("AIMONGUS_ADMIN_TOKEN")
    System.put_env("AIMONGUS_ADMIN_TOKEN", @token)

    on_exit(fn ->
      if previous,
        do: System.put_env("AIMONGUS_ADMIN_TOKEN", previous),
        else: System.delete_env("AIMONGUS_ADMIN_TOKEN")
    end)

    :ok
  end

  test "rejects a request with no token", %{conn: conn} do
    conn = post(conn, "/admin/new-match")
    assert response(conn, 401)
  end

  test "rejects a wrong token", %{conn: conn} do
    conn = post(conn, "/admin/new-match", %{token: "nope"})
    assert response(conn, 401)
  end

  test "accepts the configured token via params", %{conn: conn} do
    # no manager running under the global name in test → gated pass hits 503
    conn = post(conn, "/admin/new-match", %{token: @token})
    assert response(conn, 503)
  end

  test "accepts the configured token via the x-admin-token header", %{conn: conn} do
    conn =
      conn
      |> put_req_header("x-admin-token", @token)
      |> post("/admin/new-match")

    assert response(conn, 503)
  end

  test "a valid token restarts the manager's match", %{conn: conn} do
    match_id = "admin-#{System.unique_integer([:positive])}"

    manager =
      start_supervised!(
        {Manager,
         name: Manager,
         match_id: match_id,
         agents: false,
         record: false,
         players: [%{id: "red", pos: {4, 2}}, %{id: "blue", pos: {5, 2}}],
         game_config: %{auto_tick: false}}
      )

    pid1 =
      Enum.find_value(1..300, fn _ ->
        case Registry.lookup(Aimongus.MatchRegistry, match_id) do
          [{pid, _}] -> pid
          _other -> Process.sleep(10) && nil
        end
      end)

    assert is_pid(pid1)
    assert Process.whereis(Manager) == manager

    conn = post(conn, "/admin/new-match", %{token: @token})
    assert response(conn, 202)

    # the forced restart swapped in a fresh GameServer
    assert Enum.find_value(1..300, fn _ ->
             case Registry.lookup(Aimongus.MatchRegistry, match_id) do
               [{pid, _}] when pid != pid1 -> pid
               _other -> Process.sleep(10) && nil
             end
           end)
  end

  test "everything is denied when AIMONGUS_ADMIN_TOKEN is unset", %{conn: conn} do
    System.delete_env("AIMONGUS_ADMIN_TOKEN")

    conn = post(conn, "/admin/new-match", %{token: @token})
    assert response(conn, 403)
  end
end
