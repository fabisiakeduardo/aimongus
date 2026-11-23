# AImongUS

Autonomous social-deduction matches played by LLM agents, rendered live in the
browser. Nine pawns walk a Skeld-style ship, work tasks, call meetings, argue,
lie, and vote — while you watch.

Built to explore Elixir's concurrency model: every pawn is its own GenServer
polling an authoritative game engine, and the match runs under OTP
supervision. The spectator UI is Phoenix LiveView with a Three.js canvas for
the ship.

## Running it

Requires Elixir ~> 1.15 / OTP ~> 26 and Node (for esbuild/npm assets).

```sh
mix setup
AIMONGUS_LLM=stub mix phx.server
```

Open http://localhost:4000/watch. The `stub` adapter plays matches locally
with scripted agents — no API keys, no cost.

## LLM backends

`AIMONGUS_LLM` selects the adapter each pawn uses to think:

| Value   | Adapter          | Notes                                   |
| ------- | ---------------- | --------------------------------------- |
| `stub`  | `LLM.Stub`       | Deterministic scripted player, free     |
| `devin` | `LLM.DevinCLI`   | Pipes prompts through the `devin` CLI   |
| `codex` | `LLM.CodexCLI`   | Pipes prompts through `codex exec`      |

An OpenRouter-backed adapter also exists for direct HTTP calls.

## What a match looks like

- **Roles** — crewmates, two impostors who don't know each other (friendly
  fire is on), plus sheriff, medic, jester, and others depending on the mix.
- **Vision** — pawns only see inside their vision radius with line of sight.
  Bodies, kills, and players outside it simply don't exist to them.
- **Tasks** — crew channels on task spots; finishing the shared pool wins the
  match. Impostors fake theirs.
- **Kills & witnesses** — a kill in someone's vision gives them a permanent
  memory of it. Expect "I SAW Red kill Blue" at the next meeting.
- **Meetings** — sequential floor, real discussion. Agents accuse from their
  own sighting ledger (who was seen near the body, who's been invisible all
  game), defend with alibis, corroborate or tear down each other's claims —
  and killers fabricate alibis that can be caught.
- **Sabotage** — lights shrink vision; reactor starts a meltdown countdown
  the crew must fix or lose.
- **Replays** — every match is recorded as JSONL under `priv/replays/` and can
  be played back.

## Architecture

```
Game.Server      authoritative match state — tick loop, rules, phase machine
Agent.Server     one GenServer per pawn — polls its filtered view, calls the LLM
LLM.Prompt       per-agent view → text (information isolation is enforced here)
LLM.Intent       strict parser — LLM output must be a small intent JSON
Match.Manager    auto-loops matches, enforces a spend budget
Replay.*         recorder + playback on the same event bus
SpectateLive     LiveView shell — feed, meetings, votes, overlays
ship3d.js        Three.js scene — the map, pawns, props, interpolation
```

The engine is a pure tick loop: agents submit intents (`move_to`, `do_task`,
`kill`, `speak`, `vote`, `sabotage`…), the server validates them against
rules (range, cooldown, line of sight, role), and broadcasts events. Nothing
reaches a pawn's prompt that it couldn't have observed.

## Tests

```sh
mix test        # ~340 tests
mix precommit   # compile + format + lint + tests
```

## Stack

Elixir · Phoenix LiveView · OTP · Three.js · esbuild · Tailwind
