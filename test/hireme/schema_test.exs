defmodule Hireme.SchemaTest do
  # docs/rebuild.md: "`mix test` fails when a checked-in output differs from
  # a fresh emit". The check also holds the Rust and Elixir readings of the
  # declaration to the same canonical bytes.
  use ExUnit.Case, async: false

  alias Mix.Tasks.Hireme.Schema, as: SchemaTask

  test "the checked-in baseline and TypeScript are a fresh emit, and both parsers read the declaration alike" do
    Mix.shell(Mix.Shell.Process)

    try do
      SchemaTask.run(["--check"])
      assert_received {:mix_shell, :info, ["schema: " <> _]}
    after
      Mix.shell(Mix.Shell.IO)
    end
  end
end

defmodule Hireme.SchemaCapTest do
  # Every table an account owns is bounded by its declared cap.
  use Hireme.WireCase, async: false

  test "every stored table an account owns has a cap, and a write past it is refused cap", %{
    account: a
  } do
    for t <- Schema.tables(),
        t.residency in [:resident, :server],
        not t.global,
        do: assert(is_integer(t.cap) and t.cap > 0, t.name)

    cap = Schema.table(:profiles).cap
    ops = for i <- 1..cap, do: op(:put, :profiles, %{slug: "p#{i}", name: "P#{i}"})
    {acks, []} = run(a.id, ops)
    assert length(acks) == cap

    {[], [nack]} = run(a.id, op(:put, :profiles, %{slug: "one-more", name: "One more"}))
    assert nack.refusal == :cap
  end
end
