defmodule AimongusWeb.SpectateAdminTest do
  # async: false — mutates AIMONGUS_ADMIN_TOKEN process-global env
  use AimongusWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Aimongus.Game.Server
  alias Aimongus.Match.Manager

  @token "super-secret-admin-token"

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

  defp wait_for_game(match_id, old_pid \\ nil, tries \\ 300) do
    case Registry.lookup(Aimongus.MatchRegistry, match_id) do
      [{pid, _}] when pid != old_pid ->
        pid

      _other when tries > 0 ->
        Process.sleep(10)
        wait_for_game(match_id, old_pid, tries - 1)

      _other ->
        nil
    end
  end

  describe "admin config panel gating" do
    test "shows disabled notice when AIMONGUS_ADMIN_TOKEN is unset", %{conn: conn} do
      System.delete_env("AIMONGUS_ADMIN_TOKEN")

      {:ok, view, _html} = live(conn, "/watch?match=admin-disabled")
      refute has_element?(view, "#admin-panel")

      view |> element("#admin-toggle") |> render_click()

      assert has_element?(view, "#admin-panel")
      assert render(view) =~ "Admin controls disabled"
      refute has_element?(view, "#admin-unlock-form")
      refute has_element?(view, "#admin-config-form")
    end

    test "rejects an invalid token and keeps the config form hidden", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/watch?match=admin-wrong-token")

      view |> element("#admin-toggle") |> render_click()
      assert has_element?(view, "#admin-unlock-form")

      view
      |> form("#admin-unlock-form", %{"admin_auth" => %{"token" => "wrong-token"}})
      |> render_submit()

      assert has_element?(view, "#admin-auth-error")
      refute has_element?(view, "#admin-config-form")
    end

    test "unlocks with valid token and applies agent_count, role mix and speed to Manager", %{
      conn: conn
    } do
      match_id = "admin-live-#{System.unique_integer([:positive])}"

      _mgr =
        start_supervised!(
          {Manager,
           name: Manager,
           match_id: match_id,
           agents: false,
           record: false,
           game_config: %{auto_tick: false}}
        )

      pid1 = wait_for_game(match_id)
      assert is_pid(pid1)

      {:ok, view, _html} = live(conn, "/watch?match=#{match_id}")
      view |> element("#admin-toggle") |> render_click()

      view
      |> form("#admin-unlock-form", %{"admin_auth" => %{"token" => @token}})
      |> render_submit()

      assert has_element?(view, "#admin-config-form")

      view
      |> form("#admin-config-form", %{
        "match_config" => %{
          "agent_count" => "6",
          "impostors" => "1",
          "sheriff" => "true",
          "medic" => "false",
          "vigilante" => "true",
          "jester" => "true",
          "serial_killer" => "false",
          "speed" => "2.0"
        }
      })
      |> render_submit()

      pid2 = wait_for_game(match_id, pid1)
      assert is_pid(pid2)

      state = Server.state(match_id)
      assert map_size(state.players) == 6

      assert Enum.sort(state.config.roles) ==
               Enum.sort([:impostor, :sheriff, :vigilante, :jester, :crewmate, :crewmate])

      assert state.config.tick_ms == 50
    end

    test "validates invalid role mix before starting a match", %{conn: conn} do
      {:ok, view, _html} = live(conn, "/watch?match=admin-validate")
      view |> element("#admin-toggle") |> render_click()

      view
      |> form("#admin-unlock-form", %{"admin_auth" => %{"token" => @token}})
      |> render_submit()

      # 4 players with 2 impostors (impostors >= remaining crew -> invalid)
      html =
        view
        |> form("#admin-config-form", %{
          "match_config" => %{
            "agent_count" => "4",
            "impostors" => "2",
            "sheriff" => "true",
            "medic" => "true",
            "vigilante" => "true",
            "jester" => "false",
            "serial_killer" => "false",
            "speed" => "1.0"
          }
        })
        |> render_submit()

      assert html =~ "admin-config-error"
    end
  end
end
