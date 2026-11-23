defmodule Aimongus.Replay.Codec do
  @moduledoc """
  Tagged-JSON encoding for the Erlang terms broadcast on `match:<id>`.

  Game events are tuples with atoms (`{:killed, "p2", "p1", {6, 2}}`,
  `{:role_assigned, "p1", :impostor}`, `{:game_over, {:solo, "p5"}}`) —
  none of which survive a plain `Jason.encode!/1`. The codec maps every
  non-JSON-native term to a single-key tag object:

    * atom → `%{"a" => name}` (covers `nil`/`true`/`false`, which are atoms)
    * tuple → `%{"t" => [encoded elements]}`
    * map → `%{"m" => [[encoded_key, encoded_value], ...]}` (pair list
      keeps non-string keys and key order irrelevant)
    * list → JSON array of encoded elements
    * binary/integer/float → as-is

  Decoding is unambiguous because the encoder only ever emits
  single-key tag objects for non-scalars — a real map always arrives
  under the `"m"` tag, so no term can decode to the wrong type.

  Chosen over `:erlang.term_to_binary` + base64 so replays stay
  human-readable, diffable, and decodable across OTP versions.

  Caveats: charlists decode as integer lists (the game only uses
  binaries), and `String.to_atom/1` is used on decode — replay files
  are trusted local artifacts; do not decode untrusted input.
  """

  @atom_tag "a"
  @tuple_tag "t"
  @map_tag "m"

  @doc "Converts an Erlang term into a Jason-encodable structure."
  @spec encode(term()) :: term()
  def encode(term) when is_atom(term), do: %{@atom_tag => Atom.to_string(term)}

  def encode(term) when is_tuple(term) do
    %{@tuple_tag => term |> Tuple.to_list() |> Enum.map(&encode/1)}
  end

  def encode(term) when is_map(term) do
    %{@map_tag => Enum.map(term, fn {k, v} -> [encode(k), encode(v)] end)}
  end

  def encode(term) when is_list(term), do: Enum.map(term, &encode/1)

  # binaries and numbers are already JSON-native
  def encode(term), do: term

  @doc "Inverse of `encode/1` on a `Jason.decode!/1` structure."
  @spec decode(term()) :: term()
  def decode(%{@atom_tag => name} = tagged) when map_size(tagged) == 1 do
    String.to_atom(name)
  end

  def decode(%{@tuple_tag => elements} = tagged)
      when map_size(tagged) == 1 and is_list(elements) do
    elements |> Enum.map(&decode/1) |> List.to_tuple()
  end

  def decode(%{@map_tag => pairs} = tagged) when map_size(tagged) == 1 and is_list(pairs) do
    Map.new(pairs, fn [k, v] -> {decode(k), decode(v)} end)
  end

  def decode(list) when is_list(list), do: Enum.map(list, &decode/1)

  # an untagged map can only come from a hand-edited file — preserve it
  # with string keys rather than crash
  def decode(map) when is_map(map), do: Map.new(map, fn {k, v} -> {k, decode(v)} end)

  def decode(scalar), do: scalar
end
