defmodule Hireme.Grants do
  @moduledoc """
  What a wire session may read and write: its masks, the domain of a table
  or command, and the first of the sequencer's six checks.

  A key carries a `read_mask` and a `write_mask` over the five domains
  (world 1, desk 2, mail 4, lanes 8, corpus 16) and `may_delete`. A browser
  session is the operator: every domain both ways and `may_delete`. Tables of
  the `system` domain, `citations` and `trusted_hosts` are in no mask:
  nothing reads or writes them through a mask (`history` reads citations
  under the cited table's read bit).
  """

  import Bitwise
  alias Hireme.Schema

  @all 0b11111
  @outside ["citations", "trusted_hosts"]

  defstruct actor: :key, key_id: nil, read_mask: 0, write_mask: 0, may_delete: false

  @type t :: %__MODULE__{
          actor: :operator | :key,
          key_id: pos_integer | nil,
          read_mask: non_neg_integer,
          write_mask: non_neg_integer,
          may_delete: boolean
        }

  @doc "The operator's grants, held by every browser session."
  def operator,
    do: %__MODULE__{actor: :operator, read_mask: @all, write_mask: @all, may_delete: true}

  @doc "A key's grants, from `Hireme.Keys.authenticate/2`."
  def key(%{id: id, read_mask: r, write_mask: w, may_delete: d}),
    do: %__MODULE__{
      actor: :key,
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
  def bit(%{name: name}) when name in @outside, do: 0
  def bit(%{domain: domain}), do: Schema.domain_bit(domain)

  def bit(name) when is_atom(name) or is_integer(name), do: bit(Schema.table(name))

  @doc "Whether the grants read this table at all."
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

  @doc "Whether a single column is visible to these grants."
  def column?(%__MODULE__{actor: actor}, col),
    do: not col.server_only and (not col.private or actor == :operator)

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
