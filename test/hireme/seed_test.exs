defmodule Hireme.SeedTest do
  use ExUnit.Case, async: true

  test "seed/ is the repository directory, not the build priv tree" do
    dir = Hireme.Seed.seed_dir()

    assert Path.basename(dir) == "seed"
    refute dir =~ "_build"
    assert File.dir?(Path.dirname(dir))
  end
end
