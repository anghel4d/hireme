defmodule HiremeWeb.Gate do
  @moduledoc """
  The BEAM end of the WebTransport gate (`native/gate`).

  Config (`config :hireme, HiremeWeb.Gate`): `socket`, the Unix socket the
  gate dials for each session; `url`, the address a page connects to;
  `cmd`, the gate's command line, run as this node's Port; `hash_file`,
  where a self-signed gate writes its certificate's SHA-256 (hex) for the
  page to pin; `env`, extra environment for the Port. Without `socket` no
  gate runs, and with `config :hireme, :gate, false` (HIREME_GATE=off)
  neither does this module's process: the wire runs over `/wire` alone.
  """

  use GenServer

  defp config, do: Application.get_env(:hireme, __MODULE__, [])

  defp enabled?, do: Application.get_env(:hireme, :gate, true) != false and config()[:socket] != nil

  @doc "The gate's public URL, or nil when no gate runs."
  @spec url() :: String.t() | nil
  def url, do: if(enabled?(), do: config()[:url])

  @doc """
  The hex SHA-256 of a self-signed gate's certificate, for the page's
  `serverCertificateHashes`; nil for a gate with a CA certificate, or none.
  """
  @spec cert_hash() :: String.t() | nil
  def cert_hash do
    with true <- enabled?(),
         file when is_binary(file) <- config()[:hash_file],
         {:ok, text} <- File.read(file),
         hash when hash != "" <- String.trim(text) do
      hash
    else
      _ -> nil
    end
  end

  @doc false
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    if enabled?(), do: {:ok, %{}}, else: :ignore
  end
end
