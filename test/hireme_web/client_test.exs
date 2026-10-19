defmodule HiremeWeb.ClientTest do
  # The client's pure modules under Bun's test runner (assets/test/*.test.mjs).
  # A gate (HIREME_GATE_STRICT set) must have bun; elsewhere a missing bun only skips.
  use ExUnit.Case, async: true

  @bun System.find_executable("bun")
  if @bun == nil and System.get_env("HIREME_GATE_STRICT") in [nil, ""],
    do:
      @moduletag(skip: "bun is not on PATH (a gate, with HIREME_GATE_STRICT set, fails instead)")

  test "the client's test files pass" do
    bun = @bun || flunk("bun is not on PATH: the gate cannot run assets/test")
    root = Path.expand("../..", __DIR__)

    assert Path.wildcard(Path.join(root, "assets/test/*.test.mjs")) != [],
           "no assets/test/*.test.mjs"

    {out, status} = System.cmd(bun, ["test", "./assets/test/"], cd: root, stderr_to_stdout: true)
    assert status == 0 and out =~ ~r/\b0 fail\b/, out
  end
end
