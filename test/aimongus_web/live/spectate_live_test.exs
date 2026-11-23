defmodule AimongusWeb.SpectateLiveTest do
  use AimongusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Aimongus.Game.Server
  alias Aimongus.Game.Map, as: GameMap
  alias Aimongus.Game.Personality

  # Cafeteria (C) / MedBay (M) joined by a one-tile corridor at (6, 2).
  @ascii """
  ############
  #CCCCC#MMMM#
  #CT1CC.MMMM#
  #CT2CC#MMMM#
  #CBCCC#MMMM#
  ############

  C: Cafeteria
  M: MedBay
  """

  defp test_map, do: GameMap.parse(@ascii)

  defp match_id, do: "spectate-#{System.unique_integer([:positive])}"

  defp start_match(players, config \\ %{}) do
    id = match_id()

    config =
      %{
        map: test_map(),
        players: players,
        roles: [:impostor, :crewmate, :crewmate],
        shuffle_roles: false,
        tasks_per_player: 2,
        auto_tick: false
      }
      |> Map.merge(config)

    {:ok, _pid} = Server.start_link(id, config)
    id
  end

  defp broadcast(match_id, event) do
    Phoenix.PubSub.broadcast(Aimongus.PubSub, "match:#{match_id}", event)
  end

  defp card(overrides \\ %{}) do
    base = %{
      deceptiveness: 9,
      aggression: 2,
      paranoia: 5,
      chattiness: 8,
      loyalty: 4,
      risk: 10
    }

    {:ok, card} = Personality.new(Map.merge(base, overrides))
    card
  end

  describe "mount" do
    test "renders the map grid and one pawn per player", %{conn: conn} do
      id = start_match([%{id: "red", name: "Red"}, %{id: "blue", name: "Blue"}])

      {:ok, _view, html} = live(conn, "/watch?match=#{id}")

      assert html =~ ~s(id="ship-map")
      assert html =~ "Cafeteria"
      assert html =~ "MedBay"
      assert html =~ "&quot;red&quot;:"
      assert html =~ "&quot;blue&quot;:"
    end

    test "shows a waiting state when no match is running", %{conn: conn} do
      {:ok, _view, html} = live(conn, "/watch?match=#{match_id()}")

      assert html =~ "Waiting for match"
    end
  end

  describe "live events" do
    test "{:moved, id, pos} updates the pawn position", %{conn: conn} do
      id = start_match([%{id: "red", pos: {2, 2}}])

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")

      assert view |> element("#ship-state") |> render() =~ ~s(&quot;p&quot;:[2,2])

      broadcast(id, {:moved, "red", {5, 4}})

      assert view |> element("#ship-state") |> render() =~ ~s(&quot;p&quot;:[5,4])
    end

    test "feed shows meeting speech, whispers and system events", %{conn: conn} do
      id = start_match([%{id: "red", name: "Red"}, %{id: "blue", name: "Blue"}])

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")

      broadcast(id, {:body_reported, "red", {6, 2}})
      broadcast(id, {:meeting_started, {:report, "red"}})
      broadcast(id, {:spoke, "red", "I found Blue's body in the corridor"})
      broadcast(id, {:whisper, "blue", "red", ["red", "blue"], "psst, it wasn't me"})

      html = render(view)

      assert html =~ "reported a body"
      assert html =~ "I found Blue&#39;s body in the corridor"
      assert html =~ "psst, it wasn&#39;t me"
      assert html =~ "whispered"
    end

    test "a kill drops a body marker and dims the pawn", %{conn: conn} do
      id = start_match([%{id: "red", pos: {2, 2}}, %{id: "blue", pos: {3, 2}}])

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")

      broadcast(id, {:killed, "blue", "red", {3, 2}})

      html = render(view)
      assert html =~ ~s(&quot;bodies&quot;:[{&quot;c&quot;)
      assert html =~ ~s(&quot;p&quot;:[3,2])

      assert view |> element("#ship-state") |> render() =~
               ~s(&quot;blue&quot;:{&quot;a&quot;:false)
    end
  end

  describe "replays (no GameServer registered)" do
    # The MatchManager's replay fallback re-broadcasts recorded events on
    # a match topic that has no GameServer behind it. The view can't
    # resync against Server.state/1 — join/move events must populate the
    # players map directly or pawns never render.
    test "player_joined and moved populate pawns without a server", %{conn: conn} do
      id = match_id()

      {:ok, view, html} = live(conn, "/watch?match=#{id}")
      assert html =~ "Waiting for match"

      broadcast(id, {:player_joined, "red", "Red", {4, 2}})
      broadcast(id, {:player_joined, "blue", "Blue", {5, 2}})
      broadcast(id, :match_started)
      broadcast(id, {:role_assigned, "red", :impostor})
      broadcast(id, {:moved, "blue", {6, 2}})

      html = render(view)
      refute html =~ "Waiting for match"
      assert html =~ ~s(&quot;red&quot;:{)
      assert html =~ ~s(&quot;blue&quot;:{)
      html = render(view)
      assert html =~ ~s(&quot;blue&quot;:{&quot;a&quot;:true)
      assert html =~ ~s(&quot;p&quot;:[6,2])
    end

    test "a moved event for a player whose join was missed still upserts a pawn", %{
      conn: conn
    } do
      id = match_id()

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")

      broadcast(id, {:moved, "green", {3, 3}})

      assert view |> element("#ship-state") |> render() =~ ~s(&quot;green&quot;:{)
    end
  end

  describe "mind panel" do
    test "clicking a pawn opens the panel with the personality card", %{conn: conn} do
      id =
        start_match([
          %{id: "red", name: "Red", pos: {4, 2}, personality: card()},
          %{id: "blue", name: "Blue", pos: {8, 2}}
        ])

      {:ok, view, html} = live(conn, "/watch?match=#{id}")
      refute html =~ ~s(id="mind-panel")

      html = view |> element("#ship-map") |> render_hook("select_agent", %{"id" => "red"})

      assert html =~ ~s(id="mind-panel")
      assert html =~ "Red"
      assert html =~ "Cafeteria"
      # trait values from the card, described by Personality.describe/1
      assert html =~ "a master of lies"
      assert html =~ "peaceful"
      assert html =~ "reckless"
      # no reasoning broadcast yet
      assert html =~ "thinking"
    end

    test "the panel shows the latest reasoning summary", %{conn: conn} do
      id = start_match([%{id: "red", name: "Red", pos: {4, 2}}])

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")

      broadcast(id, {:reasoning, "red", "Blue is shadowing me"})
      html = view |> element("#ship-map") |> render_hook("select_agent", %{"id" => "red"})

      assert html =~ "Blue is shadowing me"
      refute html =~ "thinking"
    end

    test "a second click or the close button deselects the agent", %{conn: conn} do
      id = start_match([%{id: "red", pos: {4, 2}}, %{id: "blue", pos: {8, 2}}])

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")

      map = element(view, "#ship-map")

      assert render_hook(map, "select_agent", %{"id" => "red"}) =~ ~s(id="mind-panel")
      refute render_hook(map, "select_agent", %{"id" => "red"}) =~ ~s(id="mind-panel")

      # clicking a different pawn switches the selection
      html = render_hook(map, "select_agent", %{"id" => "blue"})
      assert html =~ ~s(id="mind-panel")

      refute view |> element("#mind-panel-close") |> render_click() =~ ~s(id="mind-panel")
    end

    test "dead players show their status in the panel", %{conn: conn} do
      id = start_match([%{id: "red", pos: {4, 2}}, %{id: "blue", pos: {5, 2}}])

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")

      broadcast(id, {:killed, "blue", "red", {5, 2}})
      html = view |> element("#ship-map") |> render_hook("select_agent", %{"id" => "blue"})

      assert html =~ ~s(id="mind-panel")
      assert html =~ "Dead"
    end
  end

  describe "sound events" do
    test "match start, kill and meeting events push sound commands to the client",
         %{conn: conn} do
      id = start_match([%{id: "red", name: "Red"}, %{id: "blue", name: "Blue"}])

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")

      broadcast(id, :match_started)
      assert_push_event view, "sound", %{name: "ambient"}

      broadcast(id, {:killed, "blue", "red", {3, 2}})
      assert_push_event view, "sound", %{name: "kill"}

      broadcast(id, {:body_reported, "red", {3, 2}})
      assert_push_event view, "sound", %{name: "report"}

      broadcast(id, {:button_pressed, "red"})
      assert_push_event view, "sound", %{name: "report"}

      broadcast(id, {:meeting_started, {:report, "red"}})
      assert_push_event view, "sound", %{name: "siren"}
    end

    test "voting, ejection and game over push their stingers", %{conn: conn} do
      id = start_match([%{id: "red", name: "Red"}, %{id: "blue", name: "Blue"}])

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")

      broadcast(id, {:voted, "red", "blue"})
      assert_push_event view, "sound", %{name: "vote"}

      broadcast(id, {:ejected, "blue", :crewmate})
      assert_push_event view, "sound", %{name: "eject"}

      broadcast(id, {:game_over, :crew})
      assert_push_event view, "sound", %{name: "win"}
    end

    test "an impostor/solo victory plays the lose stinger", %{conn: conn} do
      id = start_match([%{id: "red", name: "Red"}])

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")

      broadcast(id, {:game_over, :impostors})
      assert_push_event view, "sound", %{name: "lose"}
    end

    test "the mute toggle flips the assign and syncs the hook", %{conn: conn} do
      id = start_match([%{id: "red", name: "Red"}])

      {:ok, view, html} = live(conn, "/watch?match=#{id}")
      assert html =~ ~s(id="sound-toggle")
      assert html =~ "Enable sound"

      html = view |> element("#sound-toggle") |> render_click()
      assert html =~ "Mute sound"
      assert_push_event view, "sound", %{name: "control", muted: false, ambient: true}

      html = view |> element("#sound-toggle") |> render_click()
      assert html =~ "Enable sound"
      assert_push_event view, "sound", %{name: "control", muted: true, ambient: false}
    end
  end

  describe "feed styling" do
    test "whisper lines are styled distinctly from meeting speech", %{conn: conn} do
      id = start_match([%{id: "red", name: "Red"}, %{id: "blue", name: "Blue"}])

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")

      broadcast(id, {:spoke, "red", "I saw Blue near the vent"})
      broadcast(id, {:whisper, "blue", "red", ["red", "blue"], "meet me in nav"})

      speech = view |> element("#feed-1") |> render()
      whisper = view |> element("#feed-2") |> render()

      assert speech =~ "feed-speech"
      refute speech =~ "italic"
      refute speech =~ "whispered"

      assert whisper =~ "feed-whisper"
      assert whisper =~ "italic"
      assert whisper =~ "whispered"
    end
  end

  describe "art direction & overlays" do
    test "meeting and voting show the conference table overlay with seats and vote checks", %{
      conn: conn
    } do
      id = start_match([%{id: "red", name: "Red"}, %{id: "blue", name: "Blue"}])

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")
      refute has_element?(view, "#meeting-overlay")

      broadcast(id, {:meeting_started, {:button, "red"}})
      assert has_element?(view, "#meeting-overlay")
      assert view |> element("#meeting-overlay") |> render() =~ "Emergency meeting"

      broadcast(id, :voting_started)
      assert view |> element("#meeting-overlay") |> render() =~ "Vote now"

      broadcast(id, {:voted, "red", "blue"})
      assert view |> element("#meeting-overlay") |> render() =~ "✓"

      broadcast(id, :meeting_ended)
      refute has_element?(view, "#meeting-overlay")
    end

    test "kill emits a flash overlay that clears on :fx_clear", %{conn: conn} do
      id = start_match([%{id: "red", pos: {2, 2}}, %{id: "blue", pos: {3, 2}}])

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")

      broadcast(id, {:killed, "blue", "red", {3, 2}})
      assert has_element?(view, "#kill-flash-1")
      assert has_element?(view, "#fx-1")

      send(view.pid, {:fx_clear, 1})
      refute has_element?(view, "#kill-flash-1")
      refute has_element?(view, "#fx-1")
    end

    test "ejection adds the drift class and a new match_started resets it", %{conn: conn} do
      id = start_match([%{id: "red", name: "Red"}, %{id: "blue", name: "Blue"}])

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")

      broadcast(id, {:ejected, "blue", :impostor})

      assert view |> element("#ship-state") |> render() =~
               ~s(&quot;blue&quot;:{&quot;a&quot;:false,&quot;c&quot;:&quot;#eab308&quot;,&quot;e&quot;:true)

      broadcast(id, {:game_over, :crew})
      assert has_element?(view, "#gameover-banner")

      broadcast(id, :match_started)
      refute view |> element("#ship-state") |> render() =~ ~s(&quot;e&quot;:true)
      refute has_element?(view, "#gameover-banner")
    end

    test "wraps the spectator view in the game layout with flash_group", %{conn: conn} do
      id = start_match([%{id: "red", name: "Red"}])

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")
      assert has_element?(view, "#flash-group")
    end
  end
end
