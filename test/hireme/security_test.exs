defmodule Hireme.SecurityTest do
  use ExUnit.Case, async: true

  alias Hireme.Security

  defp only(:a, _), do: :ok

  test "a crash log names the kind and the frames' arities, never a message or an argument" do
    line =
      try do
        only("Subject: the secret subject", "ada@example.com")
      rescue
        e -> Security.trace(e, __STACKTRACE__)
      end

    assert line =~ ~r/\AFunctionClauseError\n/
    assert line =~ ~r/Hireme\.SecurityTest\.only\/2/
    assert line =~ "security_test.exs:"
    refute line =~ "secret"
    refute line =~ "ada@"
    assert Security.trace(:exit, []) =~ ~r/\A:exit\n/
  end
end
