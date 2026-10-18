defmodule Hireme.Kernel do
  @moduledoc """
  The sequencer's copy of the Rust kernel: one NIF resource per account,
  a cache of the account's resident rows. SQLite is the authority; the
  resource is built from a BOOT body read from it (at sequencer start and
  after any failure) and fed the same PATCH bodies subscribers get, op by
  op, so `judge/3` always sees the rows the next write lands on.

  `judge` is meant to stay under 200 µs on a normal scheduler. Its time is
  tracked as a moving average; past 1 ms the calls move to the dirty-CPU
  variant, and back once it falls under. A panic inside the kernel comes
  back as `{:error, :panic}`; the sequencer rebuilds the resource from
  SQLite and retries the op once.
  """

  alias Hireme.Kernel.Nif

  defstruct [:res, avg_us: 0]

  @type t :: %__MODULE__{res: reference(), avg_us: non_neg_integer}

  @dirty_above_us 1_000

  @doc "A resource loaded from a BOOT body."
  @spec new(iodata) :: t
  def new(boot_body) do
    res = Nif.new()
    :ok = Nif.load(res, IO.iodata_to_binary(boot_body))
    %__MODULE__{res: res}
  end

  @doc "Feeds one PATCH body (the rows an op wrote and the ids it deleted)."
  @spec apply(t, iodata) :: :ok | {:error, term}
  def apply(%__MODULE__{res: res}, patch_body), do: Nif.apply(res, IO.iodata_to_binary(patch_body))

  @doc """
  Check 4 of the sequencer, `domain`, for one op's raw OPS bytes. Returns
  the op's realization as effects, a refusal, or a panic, and the kernel
  with its timing updated.
  """
  @spec judge(t, binary, map) ::
          {{:ok, list} | {:refused, non_neg_integer, binary} | {:error, :panic}, t}
  def judge(%__MODULE__{res: res, avg_us: avg} = k, raw, ctx) do
    {us, result} =
      if avg > @dirty_above_us,
        do: :timer.tc(Nif, :judge_dirty, [res, raw, ctx]),
        else: :timer.tc(Nif, :judge, [res, raw, ctx])

    {result, %{k | avg_us: div(avg * 7 + us, 8)}}
  end

  @doc "Application ids in board order, optionally of one stage (an enum code)."
  @spec board_ids(t, non_neg_integer | nil) :: [pos_integer]
  def board_ids(%__MODULE__{res: res}, stage), do: Nif.board_ids(res, stage)

  @doc "The keyword extraction's version; a stored row with another one is re-extracted."
  def keywords_version, do: Nif.keywords_version()
end

defmodule Hireme.Kernel.Nif do
  @moduledoc false
  # The functions native/nif exports; the contract is Hireme.Kernel's.
  use Rustler,
    otp_app: :hireme,
    crate: "nif",
    path: "native/nif",
    # Nix builds the library itself; until native/nif exists there is nothing to build.
    skip_compilation?:
      Application.compile_env(:hireme, :nif_prebuilt, false) or
        not File.exists?(Path.expand("../../native/nif/Cargo.toml", __DIR__)),
    load_from: {:hireme, "priv/native/libnif"}

  def new, do: :erlang.nif_error(:nif_not_loaded)
  def load(_res, _boot), do: :erlang.nif_error(:nif_not_loaded)
  def apply(_res, _patch), do: :erlang.nif_error(:nif_not_loaded)
  def judge(_res, _op, _ctx), do: :erlang.nif_error(:nif_not_loaded)
  def judge_dirty(_res, _op, _ctx), do: :erlang.nif_error(:nif_not_loaded)
  def board_ids(_res, _stage), do: :erlang.nif_error(:nif_not_loaded)
  def keywords_version, do: :erlang.nif_error(:nif_not_loaded)
end
