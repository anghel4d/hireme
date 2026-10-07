defmodule Hireme.Score do
  @moduledoc """
  One employer's score out of 100, and the bands the campaign reads it in.

  A score is an integer in `0..100` or absent. The bands are closed and
  ordered: `:titan` is 100, `:high` is 90–99, `:strong` 85–89, `:middle`
  65–84, `:low` below 65, and `:unscored` when there is no score. Sorting
  puts the highest score first and unscored rows last.
  """

  @bands [:titan, :high, :strong, :middle, :low, :unscored]

  @type t :: 0..100
  @type band :: :titan | :high | :strong | :middle | :low | :unscored

  @spec bands() :: [band()]
  def bands, do: @bands

  @spec band(t() | nil) :: band()
  def band(nil), do: :unscored
  def band(100), do: :titan
  def band(n) when n >= 90, do: :high
  def band(n) when n >= 85, do: :strong
  def band(n) when n >= 65, do: :middle
  def band(n) when n >= 0, do: :low

  @spec floor(band()) :: t() | nil
  def floor(:titan), do: 100
  def floor(:high), do: 90
  def floor(:strong), do: 85
  def floor(:middle), do: 65
  def floor(:low), do: 0
  def floor(:unscored), do: nil

  @doc """
  A score from the wire: an integer, a numeric string, or `score_100`
  style floats are accepted; anything outside `0..100` is refused.
  """
  @spec parse(term()) :: {:ok, t() | nil} | :error
  def parse(nil), do: {:ok, nil}
  def parse(""), do: {:ok, nil}
  def parse(n) when is_integer(n) and n in 0..100, do: {:ok, n}
  def parse(f) when is_float(f), do: parse(round(f))

  def parse(s) when is_binary(s) do
    case Integer.parse(String.trim(s)) do
      {n, ""} -> parse(n)
      _ -> :error
    end
  end

  def parse(_), do: :error

  @spec parse_band(term()) :: {:ok, band()} | :error
  def parse_band(band) when band in @bands, do: {:ok, band}

  def parse_band(name) when is_binary(name) do
    case Enum.find(@bands, &(Atom.to_string(&1) == name)) do
      nil -> :error
      band -> {:ok, band}
    end
  end

  def parse_band(_), do: :error

  @doc """
  Sort key: higher first, unscored last.
  """
  @spec rank(t() | nil) :: integer()
  def rank(nil), do: 1
  def rank(n), do: -n

  @doc """
  Count of rows in each band, every band present, in band order.
  """
  @spec histogram([t() | nil]) :: [{band(), non_neg_integer()}]
  def histogram(scores) do
    counts = Enum.frequencies_by(scores, &band/1)
    Enum.map(@bands, &{&1, Map.get(counts, &1, 0)})
  end
end
