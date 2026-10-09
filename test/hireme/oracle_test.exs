defmodule Hireme.OracleTest do
  @moduledoc """
  The oracle's generator writes valid desks across seeds, and its dump
  judges every job, so the kernel's predictions are compared on all of
  them.
  """
  use Hireme.DataCase, async: false

  alias Hireme.Oracle

  @today ~D[2026-10-09]

  for seed <- 1..4 do
    test "seed #{seed} dumps a whole desk, before and after random ops" do
      seed = unquote(seed)
      :ok = Oracle.generate(seed, @today)
      ops = Oracle.ops(seed, 25)
      lines = Oracle.dump(@today, seed: seed, ops: ops) |> Enum.map(&Oracle.plain/1)
      by = Enum.group_by(lines, & &1["kind"])

      [%{"rows" => jobs}] = Enum.filter(by["table"], &(&1["table"] == "job_apps"))
      ids = jobs |> Enum.map(& &1["id"]) |> Enum.sort()
      assert ids != []

      assert Enum.sort(Enum.map(by["verdict"], & &1["id"])) == ids
      assert length(by["op"]) == 25
      assert Enum.any?(by["op"], &Map.has_key?(&1["result"], "ok"))

      # The lines are JSON as written.
      assert Enum.all?(lines, &(Oracle.encode(&1) |> IO.iodata_to_binary() |> Jason.decode!()))
    end
  end
end
