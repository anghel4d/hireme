defmodule HiremeWeb.ClientTest do
  @moduledoc """
  The client's pure modules under node's test runner: every
  `assets/test/*.test.mjs`, run with `node --experimental-transform-types
  --test`. A gate (HIREME_MCP set) must have node and fails without it;
  elsewhere a missing node only skips.
  """

  use ExUnit.Case, async: true

  @node System.find_executable("node")
  if @node == nil and System.get_env("HIREME_MCP") in [nil, ""],
    do: @moduletag(skip: "node is not on PATH (a gate, with HIREME_MCP set, fails instead)")

  test "the client's node:test files pass" do
    node = @node || flunk("node is not on PATH: the gate cannot run assets/test")
    root = Path.expand("../..", __DIR__)
    files = Path.wildcard(Path.join(root, "assets/test/*.test.mjs"))
    assert files != [], "no assets/test/*.test.mjs"

    {out, status} =
      System.cmd(node, ["--experimental-transform-types", "--no-warnings", "--test" | files],
        cd: root,
        stderr_to_stdout: true
      )

    assert status == 0, out
    assert out =~ ~r/# fail 0|ℹ fail 0/, out
  end
end
