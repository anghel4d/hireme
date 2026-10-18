defmodule Hireme.SchemaTest do
  # docs/rebuild.md: "`mix test` fails when a checked-in output differs from
  # a fresh emit". The check also holds the Rust and Elixir readings of the
  # declaration to the same canonical bytes.
  use ExUnit.Case, async: false

  test "the checked-in baseline and TypeScript are a fresh emit, and both parsers read the declaration alike" do
    Mix.shell(Mix.Shell.Process)

    try do
      Mix.Tasks.Hireme.Schema.run(["--check"])
      assert_received {:mix_shell, :info, ["schema: " <> _]}
    after
      Mix.shell(Mix.Shell.IO)
    end
  end
end
