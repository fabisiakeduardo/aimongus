defmodule AimongusWeb.SpectateLiveTest do
  use AimongusWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Aimongus.Game.Server
  alias Aimongus.Game.Map, as: GameMap

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
end
