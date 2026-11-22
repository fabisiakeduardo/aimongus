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
      assert html =~ ~s(id="pawn-red")
      assert html =~ ~s(id="pawn-blue")
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

      assert view |> element("#pawn-red") |> render() =~ "translate(52px, 52px)"

      broadcast(id, {:moved, "red", {5, 4}})

      assert view |> element("#pawn-red") |> render() =~ "translate(130px, 104px)"
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
      assert html =~ ~s(class="body")
      assert view |> element("#pawn-blue") |> render() =~ "ghost"
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

      html = view |> element("#pawn-red") |> render_click()

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
      html = view |> element("#pawn-red") |> render_click()

      assert html =~ "Blue is shadowing me"
      refute html =~ "thinking"
    end

    test "a second click or the close button deselects the agent", %{conn: conn} do
      id = start_match([%{id: "red", pos: {4, 2}}, %{id: "blue", pos: {8, 2}}])

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")

      assert view |> element("#pawn-red") |> render_click() =~ ~s(id="mind-panel")
      refute view |> element("#pawn-red") |> render_click() =~ ~s(id="mind-panel")

      # clicking a different pawn switches the selection
      html = view |> element("#pawn-blue") |> render_click()
      assert html =~ ~s(id="mind-panel")

      refute view |> element("#mind-panel-close") |> render_click() =~ ~s(id="mind-panel")
    end

    test "dead players show their status in the panel", %{conn: conn} do
      id = start_match([%{id: "red", pos: {4, 2}}, %{id: "blue", pos: {5, 2}}])

      {:ok, view, _html} = live(conn, "/watch?match=#{id}")

      broadcast(id, {:killed, "blue", "red", {5, 2}})
      html = view |> element("#pawn-blue") |> render_click()

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
end
