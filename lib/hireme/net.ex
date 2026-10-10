defmodule Hireme.Net do
  @moduledoc """
  Lightweight networking. Not CRM spam.

  Closed kinds: observer run, shipped artifact, public post, outreach
  draft. Closed channels: Broadside, X, other. The Broadside research
  lane URL lives in kv (`net` / `broadside_lane`).
  """

  alias Hireme.Form
  alias Hireme.Kv
  alias Hireme.Net.Entry
  alias Hireme.Repo

  @kinds [:observer, :artifact, :post, :draft]
  @channels [:broadside, :x, :other]

  @spec kinds() :: [atom()]
  def kinds, do: @kinds

  @spec channels() :: [atom()]
  def channels, do: @channels

  @spec set_lane(term()) :: {:ok, String.t()} | {:error, :lane}
  def set_lane(url) when is_binary(url) do
    trimmed = String.trim(url)
    Kv.put("net", "broadside_lane", trimmed)
    {:ok, trimmed}
  end

  def set_lane(_), do: {:error, :lane}

  @spec log(map(), Date.t()) :: {:ok, Entry.t()} | {:error, term()}
  def log(attrs, today \\ Date.utc_today()) when is_map(attrs) do
    with {:ok, kind} <- Form.closed(attrs, :kind, @kinds, nil),
         {:ok, channel} <- Form.closed(attrs, :channel, @channels, default_channel(kind)),
         {:ok, title} <- Form.required(attrs, :title),
         {:ok, shipped_on} <-
           Form.day(attrs, :shipped_on, if(kind == :draft, do: nil, else: today)) do
      %Entry{}
      |> Entry.changeset(%{
        kind: kind,
        channel: channel,
        title: title,
        url: Form.string(attrs, :url),
        body: Form.string(attrs, :body),
        shipped_on: shipped_on
      })
      |> Repo.insert()
    end
  end

  defp default_channel(:observer), do: :broadside
  defp default_channel(:post), do: :x
  defp default_channel(_), do: :other
end
