defmodule Hireme.Grants do
  @moduledoc """
  What a wire session may read and write: its masks, the domain of a table
  or command, and the first of the sequencer's six checks.

  A key carries a `read_mask` and a `write_mask` over the four domains
  (world 1, desk 2, mail 4, corpus 8) and `may_delete`. A browser
  session is the operator: every domain both ways and `may_delete`. Tables of
  the `system` domain (`trusted_hosts` among them) are in no mask: nothing
  reads or writes them through a mask.
  """

  import Bitwise
  alias Hireme.Schema

  @all Schema.domain_mask()

  defstruct actor: :key, key_id: nil, read_mask: 0, write_mask: 0, may_delete: false

  @type t :: %__MODULE__{
          actor: :operator | :key | :mail,
          key_id: pos_integer | nil,
          read_mask: non_neg_integer,
          write_mask: non_neg_integer,
          may_delete: boolean
        }

  @doc "The operator's grants, held by every browser session."
  def operator,
    do: %__MODULE__{actor: :operator, read_mask: @all, write_mask: @all, may_delete: true}

  @doc """
  The mail actor's grants: the node's Gmail connector and the domain pipe,
  which record facts (mail that arrived, a shot's outcome, the mailbox's
  state). It writes the mail domain and, for a shot's outcome, the desk's
  missions; the kernel tells it apart as neither human nor a key.
  """
  def mail,
    do: %__MODULE__{
      actor: :mail,
      read_mask: @all,
      write_mask: Schema.domain_bit(:mail) ||| Schema.domain_bit(:desk)
    }

  @doc "A key's grants, from `Hireme.Keys.authenticate/2`."
  def key(%{id: id, read_mask: r, write_mask: w, may_delete: d}),
    do: %__MODULE__{
      key_id: id,
      read_mask: r &&& @all,
      write_mask: w &&& @all,
      may_delete: d == true
    }

  @doc "The masks a preset stands for: `{read_mask, write_mask}`."
  def preset(:read_only), do: {@all, 0}
  def preset(:write_only), do: {0, @all}
  def preset(:read_write), do: {@all, @all}

  @doc "Every mask bit."
  def all, do: @all

  @doc "The mask bit of a table or command's domain; 0 for one in no mask."
  def bit(%{unmasked: true}), do: 0
  def bit(%{domain: domain}), do: Schema.domain_bit(domain)

  @doc "Whether the grants read this table at all. An account view is the operator's alone."
  def read?(%__MODULE__{actor: actor}, %{name: "acct_" <> _}), do: actor == :operator
  def read?(%__MODULE__{read_mask: m}, table), do: (m &&& bit(table)) != 0

  @doc "Whether the grants write this table at all."
  def write?(%__MODULE__{write_mask: m}, table), do: (m &&& bit(table)) != 0

  @doc """
  The columns of `table` these grants may see: never a `server_only`
  column, and a `private` one only for the operator.
  """
  def columns(%__MODULE__{actor: actor}, table) do
    Enum.reject(table.cols, &(&1.server_only or (&1.private and actor != :operator)))
  end

  @doc """
  Check 1 of the sequencer, `grant`: the write mask covers the op's domain,
  a drop has `may_delete`, a key's command or column is not `human_only`.
  `cols` are the column structs a put names. Returns `:ok` or
  `{:refused, refusal, data}`.
  """
  def check(%__MODULE__{} = g, :command, command, _table, _cols) do
    cond do
      not write?(g, Schema.table(command.table)) ->
        {:refused, :scope, %{command: command.name}}

      command.human_only and g.actor != :operator ->
        {:refused, :human_only, %{command: command.name}}

      true ->
        :ok
    end
  end

  def check(%__MODULE__{} = g, verb, _command, table, cols) do
    human = if g.actor == :operator, do: nil, else: Enum.find(cols, & &1.human_only)

    cond do
      not write?(g, table) ->
        {:refused, :scope, %{table: table.name}}

      verb == :drop and not g.may_delete ->
        {:refused, :scope, %{table: table.name, need: :may_delete}}

      human ->
        {:refused, :human_only, %{table: table.name, column: human.name}}

      true ->
        :ok
    end
  end
end
