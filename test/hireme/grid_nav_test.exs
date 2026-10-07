defmodule Hireme.GridNavTest do
  use ExUnit.Case, async: true

  alias Hireme.GridNav

  test "hjkl matches observer: j keeps the column, edges clamp" do
    assert GridNav.move(5, 2, 24, :j) == 7
    assert GridNav.move(5, 12, 24, :j) == 17
    assert GridNav.move(5, 3, 24, :j) == 8
    assert GridNav.move(0, 4, 10, :h) == 0
    assert GridNav.move(3, 4, 10, :l) == 3
    assert GridNav.move(1, 4, 10, :k) == 1
    assert GridNav.move(8, 4, 10, :j) == 8
  end

  test "arrows share the vim directions" do
    assert GridNav.dir_from_key("ArrowDown") == :j
    assert GridNav.dir_from_key("l") == :l
    assert GridNav.dir_from_key("Enter") == nil
  end

  test "column count uses the fixed tile, and the window stays bounded" do
    metrics = GridNav.metrics(16)
    assert GridNav.columns(800, metrics) == 3

    {start_idx, last_idx} = GridNav.slice(100, 3, 0, 640, metrics)
    assert start_idx == 0
    assert last_idx == 23
    assert GridNav.content_height(3, 3, metrics) > 0
  end

  test "scroll_to brings a lower row into view and leaves a visible card alone" do
    metrics = GridNav.metrics(16)
    assert GridNav.scroll_to(0, 3, 0, 640, metrics) == 0
    scrolled = GridNav.scroll_to(30, 3, 0, 640, metrics)
    assert scrolled > 0
  end
end
