defmodule HiremeWeb.ClientTest do
  @moduledoc """
  The client's pure modules under Bun's test runner: every
  `assets/test/*.test.mjs`, run with `bun test`. A gate (HIREME_MCP set)
  must have bun and fails without it; elsewhere a missing bun only skips.
  """

  use ExUnit.Case, async: true

  @bun System.find_executable("bun")
  if @bun == nil and System.get_env("HIREME_MCP") in [nil, ""],
    do: @moduletag(skip: "bun is not on PATH (a gate, with HIREME_MCP set, fails instead)")

  test "the client's test files pass" do
    bun = @bun || flunk("bun is not on PATH: the gate cannot run assets/test")
    root = Path.expand("../..", __DIR__)

    assert Path.wildcard(Path.join(root, "assets/test/*.test.mjs")) != [],
           "no assets/test/*.test.mjs"

    {out, status} = System.cmd(bun, ["test", "./assets/test/"], cd: root, stderr_to_stdout: true)

    assert status == 0, out
    assert out =~ ~r/\b0 fail\b/, out
  end
end
