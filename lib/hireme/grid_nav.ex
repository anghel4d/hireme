defmodule Hireme.GridNav do
  @moduledoc """
  Row-major card movement, the same rule as Broadside Observer.

  `h` and `l` stay on the row. `k` and `j` stay on the column. The edge
  clamps. `cols` is the live column count, so a resize changes where the
  next step lands without changing the selected index.

  Tile size is the CSS `--card-*` lengths. Keep the rem constants below
  in step with `assets/css/app.css`.
  """

  @width_rem 14.5
  @height_rem 11.25
  @gap_rem 0.5
  @inset_rem 0.5

  @type dir :: :h | :j | :k | :l
  @type metrics :: %{width: float(), height: float(), gap: float(), inset: float()}

  @spec metrics(number()) :: metrics()
  def metrics(rem) when is_number(rem) and rem > 0 do
    %{
      width: @width_rem * rem,
      height: @height_rem * rem,
      gap: @gap_rem * rem,
      inset: @inset_rem * rem
    }
  end

  @spec dir_from_key(term()) :: dir() | nil
  def dir_from_key(key) when key in ["h", "ArrowLeft"], do: :h
  def dir_from_key(key) when key in ["j", "ArrowDown"], do: :j
  def dir_from_key(key) when key in ["k", "ArrowUp"], do: :k
  def dir_from_key(key) when key in ["l", "ArrowRight"], do: :l
  def dir_from_key(_), do: nil

  @spec move(integer(), number(), integer(), dir()) :: non_neg_integer()
  def move(_index, _cols, count, _dir) when count <= 0, do: 0

  def move(index, cols, count, dir) when dir in [:h, :j, :k, :l] do
    columns = max(trunc(cols), 1)
    i = clamp(index, 0, count - 1)
    row = div(i, columns)
    col = rem(i, columns)

    {next_row, next_col} =
      case dir do
        :h -> {row, col - 1}
        :l -> {row, col + 1}
        :k -> {row - 1, col}
        :j -> {row + 1, col}
      end

    cond do
      next_row < 0 or next_col < 0 or next_col >= columns ->
        i

      true ->
        next = next_row * columns + next_col
        if next < 0 or next >= count, do: i, else: next
    end
  end

  @doc """
  How many fixed tiles fit in a scroller of `container_width` pixels.
  """
  def columns(container_width, _metrics) when container_width <= 0, do: 1

  def columns(container_width, metrics) do
    inner = container_width - metrics.inset * 2
    step = metrics.width + metrics.gap
    max(trunc((inner + metrics.gap) / step), 1)
  end

  @doc """
  Inclusive index range of the painted window. `{-1, -1}` when there are
  no cards.
  """
  def slice(count, cols, scroll_top, viewport, metrics, overscan \\ 2)

  def slice(count, _cols, _scroll_top, _viewport, _metrics, _overscan) when count <= 0 do
    {-1, -1}
  end

  def slice(count, cols, scroll_top, viewport, metrics, overscan) do
    columns = max(trunc(cols), 1)
    stride = metrics.height + metrics.gap
    scrolled = max(scroll_top - metrics.inset, 0)
    first_row = max(trunc(scrolled / stride) - overscan, 0)
    visible_rows = max(trunc(Float.ceil(max(viewport, 1) / stride)), 1) + overscan * 2
    start_idx = first_row * columns
    last_idx = min(count - 1, start_idx + visible_rows * columns - 1)

    if start_idx > last_idx, do: {-1, -1}, else: {start_idx, last_idx}
  end

  def origin(index, cols, metrics) do
    columns = max(trunc(cols), 1)
    col = rem(index, columns)
    row = div(index, columns)
    x = metrics.inset + col * (metrics.width + metrics.gap)
    y = metrics.inset + row * (metrics.height + metrics.gap)
    {x, y}
  end

  def content_height(count, _cols, _metrics) when count <= 0, do: 0.0

  def content_height(count, cols, metrics) do
    columns = max(trunc(cols), 1)
    rows = trunc(Float.ceil(count / columns))
    metrics.inset * 2 + rows * metrics.height + (rows - 1) * metrics.gap
  end

  @doc """
  Scroll offset that keeps `index` inside the viewport. Leaves the offset
  alone when the card is already fully visible.
  """
  def scroll_to(index, cols, scroll_top, viewport, metrics) do
    columns = max(trunc(cols), 1)
    row = div(max(index, 0), columns)
    y = metrics.inset + row * (metrics.height + metrics.gap)
    bottom = y + metrics.height

    cond do
      y < scroll_top -> y
      bottom > scroll_top + viewport -> max(bottom - viewport, 0)
      true -> scroll_top
    end
  end

  defp clamp(n, lo, _hi) when n < lo, do: lo
  defp clamp(n, _lo, hi) when n > hi, do: hi
  defp clamp(n, _lo, _hi), do: n
end
