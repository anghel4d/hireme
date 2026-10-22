defmodule Hireme.Outreach do
  @moduledoc """
  The OutreachItem on the node (docs/mail/outreach_type.md): the type over
  `outreach` rows as one struct per kind (`Hireme.Outreach.Email`,
  `CareersPage`, `LinkedIn`, `XDm`, `Discord`, `Other`, `Note`), each with
  the core every item has and its own fields, so function heads
  pattern-match on the kind. The base is this module: the kinds, the guards,
  the decoding of a row into its struct and the lowering of a struct to the
  put the sequencer takes.

  The structs shape data; every rule is the kernel's (`outreach::put`,
  through the NIF), so a bad construction is refused there, never checked
  here twice. Lists (`to`, `cc`, `labels`) are Elixir lists, stored
  U+001F-joined; `refs` is the References header's ids, stored
  space-separated; `headers`, `fields` and `evidence` are maps.
  """

  alias Hireme.Schema
  alias HiremeWeb.Wire.Codec

  @kinds Schema.enum(:outreach_kind)
  @modules %{
    email: Hireme.Outreach.Email,
    careers_page: Hireme.Outreach.CareersPage,
    linkedin: Hireme.Outreach.LinkedIn,
    x_dm: Hireme.Outreach.XDm,
    discord: Hireme.Outreach.Discord,
    other: Hireme.Outreach.Other,
    note: Hireme.Outreach.Note
  }
  @structs Map.values(@modules)

  if Enum.sort(Map.keys(@modules)) != Enum.sort(@kinds),
    do: raise("Hireme.Outreach's kinds are not the declaration's outreach_kind")

  # The core, by column; the implied columns and the kernel's own come last.
  @core ~w(id kind direction at subject body link report actor filing filed_by evidence seen
           corporation_id application_id contact_id mission_id rev inserted_at updated_at)a
  @readonly ~w(id rev inserted_at updated_at thread_key actor filing filed_by evidence bounced_at)a
  @sep <<0x1F>>

  @type kind :: :email | :careers_page | :linkedin | :x_dm | :discord | :other | :note
  @type t ::
          Hireme.Outreach.Email.t()
          | Hireme.Outreach.CareersPage.t()
          | Hireme.Outreach.LinkedIn.t()
          | Hireme.Outreach.XDm.t()
          | Hireme.Outreach.Discord.t()
          | Hireme.Outreach.Other.t()
          | Hireme.Outreach.Note.t()

  defguard is_item(x) when is_map(x) and :erlang.map_get(:__struct__, x) in @structs
  defguard is_email(x) when is_struct(x, Hireme.Outreach.Email)
  defguard is_kind(x, kind) when is_item(x) and :erlang.map_get(:kind, x) == kind
  defguard is_inbound(x) when is_item(x) and :erlang.map_get(:direction, x) == :inbound
  defguard is_outbound(x) when is_item(x) and :erlang.map_get(:direction, x) == :outbound
  @doc "A mission row (or map) whose kind is email: the node's send hand-off."
  defguard is_email_mission(m) when is_map(m) and :erlang.map_get(:kind, m) == :email

  @doc "The kinds, in the declaration's order."
  def kinds, do: @kinds

  @doc "The core's fields, every struct's first."
  def core, do: @core

  @doc "The struct module of a kind."
  def module(kind) when is_atom(kind), do: Map.fetch!(@modules, kind)
  def module(kind) when is_binary(kind), do: module(String.to_existing_atom(kind))

  @doc "An item's kind."
  def kind(%{kind: k}) when k in @kinds, do: k

  @doc """
  A row (`%Hireme.Rows.Outreach{}`, or a map from a find, atom or string
  keys) as the struct of its kind.
  """
  def from_row(%Hireme.Rows.Outreach{} = row), do: row |> Map.from_struct() |> from_row()

  def from_row(%{} = row) do
    get = fn name -> Map.get(row, name) || Map.get(row, Atom.to_string(name)) end
    kind = get.(:kind) |> to_atom()
    mod = module(kind)

    fields =
      for {field, column} <- mod.columns(), into: %{} do
        {field, mod.read(field, get.(column))}
      end

    core =
      for name <- @core, into: %{} do
        {name, read_core(name, get.(name))}
      end

    struct(mod, Map.merge(core, fields))
  end

  defp read_core(name, v) when name in [:direction, :actor, :filing, :filed_by], do: to_atom(v)
  defp read_core(:kind, v), do: to_atom(v)
  defp read_core(:evidence, v), do: json(v)
  defp read_core(:seen, v), do: v == true or v == 1
  defp read_core(name, v) when name in [:at, :inserted_at, :updated_at], do: time(v)
  defp read_core(_name, v), do: v

  @doc false
  def to_atom(nil), do: nil
  def to_atom(v) when is_atom(v), do: v
  def to_atom(v) when is_binary(v), do: String.to_existing_atom(v)

  @doc false
  def json(nil), do: nil
  def json(v) when is_binary(v), do: with({:error, _} <- JSON.decode(v), do: v)
  def json(v), do: v

  @doc false
  def time(nil), do: nil
  def time(%DateTime{} = t), do: t
  def time(s) when is_integer(s), do: DateTime.from_unix!(s)

  def time(s) when is_binary(s) do
    case DateTime.from_iso8601(s) do
      {:ok, t, _} -> t
      _ -> nil
    end
  end

  @doc false
  def list(nil), do: []
  def list(l) when is_list(l), do: l
  def list(s) when is_binary(s), do: s |> String.split(@sep) |> Enum.reject(&(&1 == ""))

  @doc "The writable columns of an item as a put's cells, column name to value; nothing readonly or nil."
  def cells(item) when is_item(item) do
    mod = item.__struct__

    own =
      for {field, column} <- mod.columns(), column not in @readonly do
        {Atom.to_string(column), mod.write(field, Map.fetch!(item, field))}
      end

    core =
      for name <- @core, name not in @readonly do
        {Atom.to_string(name), write_core(name, Map.fetch!(item, name))}
      end

    (core ++ own)
    |> Enum.reject(fn {_, v} -> v == nil end)
    |> Map.new()
  end

  defp write_core(:at, %DateTime{} = t), do: DateTime.to_unix(t)
  defp write_core(_name, v), do: v

  @doc """
  The op the sequencer takes (`Hireme.Sequencer.call/3`) for this item: a
  put, keyed by Message-ID when the item has one (a second pipe's copy of
  the same mail updates the first's row), or `target:` an existing row's id.
  """
  def op(item, opts \\ []) when is_item(item) do
    t = Schema.table(:outreach)
    cols = Map.new(t.cols, &{&1.name, &1})
    target = opts[:target] || 0
    keyed = target == 0 and Map.get(cells(item), "message_id") != nil
    flags = if keyed, do: 1, else: 0

    encoded =
      for {name, v} <- cells(item) do
        col = Map.fetch!(cols, name)
        {col.id, Codec.cell_type(col), Codec.to_wire(col, v)}
      end

    raw =
      Codec.encode_op(
        {opts[:op_id] || Codec.op_id(), :put, flags, t.id, target, opts[:expect_rev], encoded}
      )

    {:ok, op, ""} = Codec.op(raw)
    op
  end

  @doc "What the item's record says: sent, received, bounced; nil for a note."
  def status(%Hireme.Outreach.Email{direction: :outbound, bounced_at: b}) when b != nil,
    do: :bounced

  def status(%{direction: :outbound}), do: :sent
  def status(%{direction: :inbound}), do: :received
  def status(item) when is_item(item), do: nil

  @doc "Where the item belongs."
  def refs(item) when is_item(item),
    do: Map.take(item, [:corporation_id, :application_id, :contact_id, :mission_id])
end

defmodule Hireme.Outreach.Variant do
  @moduledoc false
  # `use Hireme.Outreach.Variant, kind: k, fields: [{field, column} | field]`:
  # the struct of one kind (the core, then its own fields), `kind/0`,
  # `columns/0` (field to column), and `read/2` / `write/2` for its own
  # fields (a list column split and joined, a json one decoded and encoded).

  defmacro __using__(opts) do
    kind = Keyword.fetch!(opts, :kind)

    pairs =
      for f <- Keyword.get(opts, :fields, []) do
        case f do
          {field, column} -> {field, column}
          field -> {field, field}
        end
      end

    quote bind_quoted: [kind: kind, pairs: pairs] do
      columns = MapSet.new(Hireme.Schema.table(:outreach).cols, & &1.name)

      for {_, column} <- pairs,
          Atom.to_string(column) not in columns,
          do: raise("#{inspect(__MODULE__)}: outreach has no column #{column}")

      @kind kind
      @pairs pairs
      @lists ~w(to cc labels)a
      @jsons ~w(headers fields)a
      @times ~w(bounced_at)a
      defstruct Enum.map(Hireme.Outreach.core(), fn
                  :kind -> {:kind, kind}
                  :seen -> {:seen, false}
                  :filing -> {:filing, :unfiled}
                  f -> {f, nil}
                end) ++ Enum.map(pairs, fn {f, _} -> {f, nil} end)

      @type t :: %__MODULE__{}

      def kind, do: @kind
      def columns, do: @pairs

      @doc false
      def read(:refs, v) when is_binary(v), do: String.split(v)
      def read(:refs, nil), do: []
      def read(:pipe, v), do: Hireme.Outreach.to_atom(v)
      def read(f, v) when f in @lists, do: Hireme.Outreach.list(v)
      def read(f, v) when f in @jsons, do: Hireme.Outreach.json(v)
      def read(f, v) when f in @times, do: Hireme.Outreach.time(v)
      def read(_f, v), do: v

      @doc false
      def write(:refs, l) when is_list(l), do: Enum.join(l, " ")
      def write(f, l) when f in @lists and is_list(l), do: Enum.join(l, <<0x1F>>)
      def write(f, m) when f in @jsons and (is_map(m) or is_list(m)), do: m
      def write(_f, v), do: v
    end
  end
end

defmodule Hireme.Outreach.Email do
  @moduledoc """
  The OutreachEmail: a mail received or sent, with the sender, recipients,
  Message-ID, threading headers, Gmail ids, labels, the few headers the
  filer reads, the pipe it came by, and its bounce.
  """

  use Hireme.Outreach.Variant,
    kind: :email,
    fields: [
      {:from, :from_addr},
      {:to, :to_addr},
      {:cc, :cc_addr},
      :reply_to,
      :message_id,
      :in_reply_to,
      :refs,
      :thread_key,
      :gmail_msgid,
      :gmail_thrid,
      :labels,
      :headers,
      :pipe,
      :bounced_at
    ]

  @doc """
  An inbound mail as the node parsed it: `message_id`, `in_reply_to`, `refs`
  (a list or the header's text), `from`, `to`, `cc`, `reply_to`, `subject`,
  `text`, `date` (a DateTime or unix seconds), `gmail_msgid`, `gmail_thrid`,
  `labels`, `pipe` (`:gmail` | `:domain`), `headers` (a map) and `report` (a
  bounce's, folded into the headers under "report").
  """
  def inbound(%{} = parsed) do
    get = fn k -> Map.get(parsed, k) || Map.get(parsed, Atom.to_string(k)) end
    headers = get.(:headers) || %{}
    headers = if r = get.(:report), do: Map.put(headers, "report", r), else: headers

    %__MODULE__{
      direction: :inbound,
      at: Hireme.Outreach.time(get.(:date)),
      subject: get.(:subject),
      body: get.(:text) || get.(:body),
      from: get.(:from),
      to: addrs(get.(:to)),
      cc: addrs(get.(:cc)),
      reply_to: get.(:reply_to),
      message_id: get.(:message_id),
      in_reply_to: get.(:in_reply_to),
      refs: refs(get.(:refs)),
      gmail_msgid: get.(:gmail_msgid),
      gmail_thrid: get.(:gmail_thrid),
      labels: List.wrap(get.(:labels)),
      headers: if(headers == %{}, do: nil, else: headers),
      pipe: Hireme.Outreach.to_atom(get.(:pipe))
    }
  end

  @doc """
  What the sender reads off an email mission in flight (its row, or a map
  of it): the mail as it goes, outbound, from the linked address.
  """
  def shot(%{kind: :email} = mission, from) when is_binary(from) do
    %__MODULE__{
      direction: :outbound,
      at: mission[:fired_at] || mission[:in_flight_at],
      subject: mission[:subject],
      body: mission[:draft],
      from: from,
      to: addrs(mission[:target]),
      cc: addrs(mission[:cc]),
      in_reply_to: mission[:in_reply_to],
      refs: refs(mission[:refs]),
      message_id: mission[:message_id],
      mission_id: mission[:id],
      application_id: mission[:application_id],
      contact_id: mission[:contact_id],
      pipe: :hireme
    }
  end

  @doc "The recipients, at most ten (the kernel's rule)."
  def recipients(%__MODULE__{to: to}), do: to

  @doc "The copied, at most ten."
  def copies(%__MODULE__{cc: cc}), do: cc

  @doc "Addresses out of comma or U+001F separated text (or a list), each bare."
  def addrs(nil), do: []
  def addrs(l) when is_list(l), do: l |> Enum.map(&bare/1) |> Enum.reject(&(&1 == ""))

  def addrs(text) when is_binary(text),
    do: text |> String.split([",", <<0x1F>>]) |> Enum.map(&bare/1) |> Enum.reject(&(&1 == ""))

  defp bare(text) do
    t = String.trim(text)

    case Regex.run(~r/<([^<>]+)>\s*$/, t) do
      [_, inner] -> String.trim(inner)
      nil -> t
    end
  end

  defp refs(nil), do: []
  defp refs(l) when is_list(l), do: l
  defp refs(s) when is_binary(s), do: String.split(s)
end

defmodule Hireme.Outreach.CareersPage do
  @moduledoc "The OutreachCareersPage: a form submitted, with its fields and the reference the page showed."
  use Hireme.Outreach.Variant, kind: :careers_page, fields: [:fields, :reference]
end

defmodule Hireme.Outreach.LinkedIn do
  @moduledoc "The OutreachLinkedIn: a LinkedIn message, by the profile's handle."
  use Hireme.Outreach.Variant, kind: :linkedin, fields: [:handle]
end

defmodule Hireme.Outreach.XDm do
  @moduledoc "The OutreachTwitterDm: an X DM, by handle (without the @)."
  use Hireme.Outreach.Variant, kind: :x_dm, fields: [:handle]
end

defmodule Hireme.Outreach.Discord do
  @moduledoc "The OutreachDiscord: a Discord message, by user or server/#channel."
  use Hireme.Outreach.Variant, kind: :discord, fields: [:handle]
end

defmodule Hireme.Outreach.Other do
  @moduledoc "The OutreachOther: a message on a channel hireme does not model, named by `channel`."
  use Hireme.Outreach.Variant, kind: :other, fields: [:channel, :handle]
end

defmodule Hireme.Outreach.Note do
  @moduledoc "The OutreachNote: a note about anything seen, markdown, with no direction."
  use Hireme.Outreach.Variant, kind: :note, fields: []
end
