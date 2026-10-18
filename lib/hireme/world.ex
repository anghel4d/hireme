defmodule Hireme.World do
  @moduledoc """
  The server-side reads: `find`, `get`, `history` and `text`, the RPC
  methods behind the world, outreach and focus lenses and the MCP tools of
  the same names. This is the only reader of server-side tables; resident
  tables read here too, under the same rules.

  Every call names its account and the session's `Hireme.Grants`, and is
  checked whole each time: the table's domain bit in the read mask, every
  column it names visible (never `server_only`, `private` only to the
  operator), and each `text` chunk again. Tables in no mask (`system`,
  `citations`, `trusted_hosts`) are not found here; a cell's citations are
  read through `history`, under the cited table's bit.

  Answers are `{:ok, map}` or `{:error, refusal, data}`, the refusal one of
  the declaration's (`not_found`, `column`, `type`, `scope`, `too_large`).

  An enum column orders and compares by its value's name, as SQLite holds
  it, not by its code.

  Paging is by keyset: `find` orders by one column then `id`, nulls last,
  and hands back an opaque `next` cursor that resumes after the last row.
  Deferred text is not inlined: `find` and `get` give its byte length and
  the first 8 bytes (hex) of its SHA-256, read from the column's stored
  `_sha` twin, and `text` the bytes.
  """

  import Ecto.Query
  require Logger
  alias Hireme.{Grants, Repo, Schema}
  alias Hireme.Rows.{Citation, Source}
  alias Hireme.Schema.Parser

  @find_limit 50
  @find_max 500
  @history_max 200
  @chunk 256 * 1024
  @int64 9_223_372_036_854_775_807

  @ops ~w(eq ne lt le gt ge in null prefix like)

  @type answer :: {:ok, map()} | {:error, atom(), map()}
  @type ctx :: %{account_id: pos_integer(), grants: Grants.t()}

  @doc """
  The RPC entry point: `schema`, `find`, `get`, `history` or `text`, for
  a session's `ctx` (`account_id` and `grants`).
  """
  @spec call(String.t(), map(), ctx()) :: answer()
  def call(method, params, %{account_id: account_id, grants: %Grants{} = grants})
      when is_map(params) do
    case method do
      "schema" -> schema(grants)
      "find" -> find(account_id, grants, params)
      "get" -> get(account_id, grants, params)
      "history" -> history(account_id, grants, params)
      "text" -> text(account_id, grants, params)
      _ -> {:error, :not_found, %{method: name_echo(method)}}
    end
  rescue
    # A value the checks let through but cannot be cast (a cursor tampered
    # with) is the caller's mistake; anything else is the server's, logged
    # and answered `internal`. Neither ends the session, and neither answer
    # carries the exception's text (it can hold the generated SQL).
    _ in [Ecto.Query.CastError, Ecto.CastError] ->
      {:error, :type, %{reason: "a value of the wrong type"}}

    e ->
      Logger.warning("world #{method}: #{Exception.format(:error, e, __STACKTRACE__)}")
      {:error, :internal, %{}}
  end

  def call(_method, params, _ctx), do: {:error, :type, %{params: inspect(params)}}

  # ------------------------------------------------------------------ schema

  @doc """
  The catalog these grants can use: every table they read or write with
  its visible columns, the commands they may send (a key never sees a
  `human_only` one) and the enums. Answers `%{"schema_rev", "wire_hash",
  "tables", "commands", "enums"}`.
  """
  @spec schema(Grants.t()) :: answer()
  def schema(%Grants{} = grants) do
    tables =
      for t <- Schema.tables(),
          t.residency in [:resident, :server, :projection],
          Grants.bit(t) != 0,
          Grants.read?(grants, t) or Grants.write?(grants, t) do
        %{
          "id" => t.id,
          "name" => t.name,
          "domain" => t.domain,
          "residency" => t.residency,
          "read" => Grants.read?(grants, t),
          "write" => Grants.write?(grants, t),
          "natural" => Enum.map(t.naturals, &Schema.key_doc/1),
          "cols" =>
            for c <- Grants.columns(grants, t) do
              %{
                "id" => c.id,
                "name" => c.name,
                "type" => c.type,
                "type_code" => c.type_code,
                "wire" => c.wire,
                "flags" => Parser.flags(c),
                "target" => c.target
              }
            end
        }
      end

    commands =
      for c <- Schema.commands(),
          Grants.write?(grants, Schema.table(c.table)),
          not c.human_only or grants.actor == :operator do
        %{
          "id" => c.id,
          "name" => c.name,
          "table" => c.table,
          "human_only" => c.human_only,
          "params" =>
            Enum.map(c.params, fn p ->
              %{
                "id" => p.id,
                "name" => p.name,
                "type" => p.type,
                "type_code" => p.type_code,
                "wire" => p.wire,
                "required" => p.required,
                "target" => p.target
              }
            end)
        }
      end

    enums = Map.new(Schema.model().enums, &{&1.name, &1.values})

    {:ok,
     %{
       "schema_rev" => Schema.schema_rev(),
       "wire_hash" => Schema.wire_hash(),
       "tables" => tables,
       "commands" => commands,
       "enums" => enums
     }}
  end

  # ------------------------------------------------------------------ find

  @doc """
  Rows of a table, a page at a time.

  Params: `table`; `where`, a map of column to a value (equality) or to
  `%{op => value}` with op one of #{Enum.join(@ops, ", ")} (`in` takes a
  list, `null` a boolean, `like` a substring, case-insensitive); `cols`, the
  columns wanted (default every visible one); `order` (default `id`) and
  `desc`; `limit` (default #{@find_limit}, at most #{@find_max}); `after`, a
  previous answer's `next`.

  Metrics and their `_on` twins come back only when named in `cols`; the
  default is every other visible column.

  Answers `%{"rows" => [...], "next" => cursor | nil}`.
  """
  @spec find(pos_integer(), Grants.t(), map()) :: answer()
  def find(account_id, %Grants{} = grants, params) do
    with {:ok, table} <- readable(grants, params["table"]),
         {:ok, cols} <- find_columns(grants, table, params["cols"]),
         {:ok, order, desc} <- order_param(grants, table, params),
         {:ok, limit} <- bound(params["limit"], @find_limit, @find_max),
         {:ok, where} <- filters(grants, table, params["where"] || %{}),
         {:ok, cursor} <- decode_cursor(params["after"]) do
      row = Schema.row(table.name)
      order_field = String.to_atom(order.name)

      # The page's ids first, narrow, then its rows by id: a sort carries
      # two columns, not every one the page shows.
      # A substring test reads every row it tests; through a subquery it
      # reads the narrowest index that holds the column instead of the rows.
      filtered =
        if scans?(params["where"]),
          do:
            where(
              from(r in row, limit: ^limit),
              [r],
              r.id in subquery(
                from(s in row, where: s.account_id == ^account_id, select: s.id)
                |> where(^where)
              )
            ),
          else: from(r in row, limit: ^limit) |> where(^where)

      page_query =
        filtered
        |> live(table)
        |> page(order, desc, cursor)
        |> order(order, desc)
        |> select([r], {r.id, field(r, ^order_field)})

      run(account_id, fn ->
        keys = Repo.all(page_query)
        ids = Enum.map(keys, &elem(&1, 0))

        by_id =
          from(r in row, where: r.id in ^ids, select: ^select_map(table, cols))
          |> Repo.all()
          |> Map.new(&{&1.id, &1})

        # A row dropped between the two reads is gone, not an error.
        rows = Enum.flat_map(ids, &List.wrap(Map.get(by_id, &1)))

        next =
          case List.last(keys) do
            {id, value} when length(keys) == limit ->
              cursor_after(%{:id => id, order_field => value}, order, cols)

            _ ->
              nil
          end

        {:ok, %{"rows" => Enum.map(rows, &out(&1, cols)), "next" => next}}
      end)
    end
  end

  # ------------------------------------------------------------------ get

  @doc """
  One row, by `id` or by its natural key: `%{"table" => t, "id" => 7}` or
  `%{"table" => "places", "key" => %{"iso2" => "PT"}}`. `cols` as in
  `find`. Answers `%{"row" => map}`.
  """
  @spec get(pos_integer(), Grants.t(), map()) :: answer()
  def get(account_id, %Grants{} = grants, params) do
    with {:ok, table} <- readable(grants, params["table"]),
         {:ok, cols} <- columns(grants, table, params["cols"]),
         {:ok, where} <- identity(grants, table, params) do
      query =
        from(r in Schema.row(table.name), where: ^where, limit: 1)
        |> live(table)
        |> select(^select_map(table, cols))

      run(account_id, fn ->
        case Repo.one(query) do
          nil -> {:error, :not_found, %{table: table.name}}
          # A row's empty cells are left out: every non-null column.
          row -> {:ok, %{"row" => row |> out(cols) |> Map.reject(fn {_, v} -> is_nil(v) end)}}
        end
      end)
    end
  end

  # ------------------------------------------------------------------ history

  @doc """
  A cell's or a row's citations, newest first: `table`, `id`, optional
  `column`, `limit` (at most #{@history_max}) and `after` (a citation id).
  The newest citation of a cell is its source; the rest are its history.
  Answers `%{"citations" => [...], "next" => id | nil}`.
  """
  @spec history(pos_integer(), Grants.t(), map()) :: answer()
  def history(account_id, %Grants{} = grants, params) do
    with {:ok, table} <- readable(grants, params["table"]),
         {:ok, id} <- id(params["id"]),
         {:ok, column} <- optional_column(grants, table, params["column"]),
         {:ok, limit} <- bound(params["limit"], 50, @history_max),
         {:ok, before} <- optional_id(params["after"]) do
      visible = for c <- Grants.columns(grants, table), do: c.name

      query =
        from(c in Citation,
          left_join: s in Source,
          on: s.id == c.source_id,
          where: c.table == ^table.name and c.row_id == ^id and c.column in ^visible,
          order_by: [desc: c.id],
          limit: ^limit,
          select: %{citation: c, source: s}
        )

      query = if column, do: where(query, [c], c.column == ^column.name), else: query
      query = if before, do: where(query, [c], c.id < ^before), else: query

      run(account_id, fn ->
        rows = Repo.all(query)
        next = if length(rows) == limit, do: List.last(rows).citation.id

        {:ok, %{"citations" => Enum.map(rows, &citation/1), "next" => next}}
      end)
    end
  end

  # A soft-deleted row is a tombstone: find, get and text pass over it, and
  # a citation still names it (history joins it whatever its state).
  defp live(query, %{soft_delete: true}), do: where(query, [r], is_nil(r.deleted_at))
  defp live(query, _table), do: query

  defp citation(%{citation: c, source: s}) do
    %{
      "id" => c.id,
      "column" => c.column,
      "value" => c.value,
      "as_of" => c.as_of,
      "actor" => c.actor,
      "key_id" => c.key_id,
      "op_id" => c.op_id,
      "at" => c.inserted_at,
      "source" =>
        s &&
          %{
            "id" => s.id,
            "url" => s.url,
            "host" => s.host,
            "publisher" => s.publisher,
            "title" => s.title,
            "kind" => s.kind
          }
    }
  end

  # ------------------------------------------------------------------ text

  @doc """
  A chunk of one text cell: `table`, `id`, `column`, `offset` (bytes,
  default 0) and `length` (default and most #{@chunk}). The chunk ends on a
  character boundary; `next` is the offset after it, nil at the end.
  Answers `%{"text", "offset", "next", "total", "sha"}`. The read mask and
  the column's visibility are checked on every chunk.
  """
  @spec text(pos_integer(), Grants.t(), map()) :: answer()
  def text(account_id, %Grants{} = grants, params) do
    with {:ok, table} <- readable(grants, params["table"]),
         {:ok, id} <- id(params["id"]),
         {:ok, column} <- text_column(grants, table, params["column"]),
         {:ok, offset} <- non_negative(params["offset"], 0, "offset"),
         {:ok, length} <- bound(params["length"], @chunk, @chunk, "length"),
         true <- offset + length + 4 <= @int64 || {:error, :too_large, %{param: "offset"}} do
      name = column.name

      query =
        from(r in Schema.row(table.name),
          where: r.id == ^id,
          select: %{
            total: fragment("length(CAST(? AS BLOB))", field(r, ^String.to_atom(name))),
            chunk:
              fragment(
                "substr(CAST(? AS BLOB), ?, ?)",
                field(r, ^String.to_atom(name)),
                ^(offset + 1),
                ^(length + 3)
              ),
            whole: field(r, ^String.to_atom(name))
          }
        )
        |> live(table)

      run(account_id, fn ->
        case Repo.one(query) do
          nil ->
            {:error, :not_found, %{table: table.name, id: id}}

          %{whole: nil} ->
            {:ok,
             %{
               "text" => nil,
               "offset" => offset,
               "next" => nil,
               "total" => 0,
               "sha" => nil,
               "untrusted" => true
             }}

          %{total: total, chunk: chunk, whole: whole} ->
            chunk(offset, length, total, chunk || "", whole)
        end
      end)
    end
  end

  # The bytes past `length` were read only to finish a character the limit
  # would split; a chunk never ends inside one.
  defp chunk(offset, length, total, bytes, whole) do
    if offset > 0 and offset < total and continuation?(:binary.at(bytes, 0)) do
      {:error, :type, %{param: "offset", reason: "inside a character"}}
    else
      text = utf8_prefix(binary_part(bytes, 0, min(length, byte_size(bytes))), bytes)
      stop = offset + byte_size(text)

      {:ok,
       %{
         "text" => text,
         "offset" => offset,
         "next" => if(stop < total, do: stop),
         "total" => total,
         "sha" => sha(whole),
         "untrusted" => true
       }}
    end
  end

  defp continuation?(b), do: Bitwise.band(b, 0xC0) == 0x80

  # The longest prefix of `bytes` (extended from `want` by at most three
  # bytes of `all`) that is whole UTF-8.
  defp utf8_prefix(want, all) do
    n = byte_size(want)

    if String.valid?(want) do
      want
    else
      Enum.find_value(1..3, fn extra ->
        if n + extra <= byte_size(all) do
          longer = binary_part(all, 0, n + extra)
          if String.valid?(longer), do: longer
        end
      end) || trim_invalid(want)
    end
  end

  defp trim_invalid(<<>>), do: <<>>

  defp trim_invalid(bytes) do
    if String.valid?(bytes),
      do: bytes,
      else: trim_invalid(binary_part(bytes, 0, byte_size(bytes) - 1))
  end

  # ------------------------------------------------------------------ checks

  defp readable(grants, name) when is_binary(name) do
    case Schema.table(name) do
      %{residency: r} = t when r in [:resident, :server] ->
        cond do
          Grants.bit(t) == 0 -> {:error, :not_found, %{table: name_echo(name)}}
          not Grants.read?(grants, t) -> {:error, :scope, %{table: name_echo(name)}}
          true -> {:ok, t}
        end

      _ ->
        {:error, :not_found, %{table: name_echo(name)}}
    end
  end

  defp readable(_grants, other), do: {:error, :type, %{param: "table", got: inspect(other)}}

  defp column(grants, table, name) when is_binary(name) do
    case Schema.column(table.name, name) do
      nil ->
        {:error, :column, %{table: table.name, column: name_echo(name)}}

      col ->
        if Grants.column?(grants, col),
          do: {:ok, col},
          else: {:error, :column, %{table: table.name, column: name_echo(name)}}
    end
  end

  defp column(_grants, table, other),
    do: {:error, :type, %{table: table.name, column: inspect(other)}}

  defp find_columns(grants, table, nil),
    do: {:ok, Enum.reject(Grants.columns(grants, table), &(&1.metric or &1.metric_of != nil))}

  defp find_columns(grants, table, names), do: columns(grants, table, names)

  defp columns(grants, table, nil), do: {:ok, Grants.columns(grants, table)}

  defp columns(grants, table, names) when is_list(names) do
    names
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn name, {:ok, acc} ->
      case column(grants, table, name) do
        {:ok, col} -> {:cont, {:ok, [col | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, cols} -> {:ok, ensure_id(Enum.reverse(cols), table)}
      error -> error
    end
  end

  defp columns(_grants, table, other),
    do: {:error, :type, %{table: table.name, cols: brief(other)}}

  defp ensure_id(cols, table) do
    if Enum.any?(cols, &(&1.name == "id")),
      do: cols,
      else: [Schema.column(table.name, "id") | cols]
  end

  defp optional_column(_grants, _table, nil), do: {:ok, nil}
  defp optional_column(grants, table, name), do: column(grants, table, name)

  # `order` is a column, or `[column, "asc" | "desc"]`; `desc: true` also
  # reverses a bare column.
  defp order_param(grants, table, params) do
    {name, desc} =
      case params["order"] do
        [name, "desc"] -> {name, true}
        [name, "asc"] -> {name, false}
        [name] -> {name, params["desc"] == true}
        name -> {name, params["desc"] == true}
      end

    with {:ok, col} <- order_column(grants, table, name), do: {:ok, col, desc}
  end

  defp order_column(grants, table, nil), do: order_column(grants, table, "id")

  defp order_column(grants, table, name) do
    with {:ok, col} <- column(grants, table, name) do
      if col.deferred or col.type in [:json, :bytes, :text],
        do:
          {:error, :column,
           %{table: table.name, column: name_echo(name), reason: "not orderable"}},
        else: {:ok, col}
    end
  end

  defp text_column(grants, table, name) do
    with {:ok, col} <- column(grants, table, name) do
      if col.type in [:text, :str, :json],
        do: {:ok, col},
        else: {:error, :column, %{table: table.name, column: name_echo(name), reason: "not text"}}
    end
  end

  defp identity(_grants, _table, %{"id" => id}) do
    with {:ok, id} <- id(id), do: {:ok, dynamic([r], r.id == ^id)}
  end

  defp identity(grants, table, %{"key" => key})
       when is_map(key) and map_size(key) > 0 and
              not is_map_key(key, :__struct__) do
    # A key names values, never a filter.
    if Enum.any?(Map.values(key), &(is_map(&1) or is_list(&1))),
      do: {:error, :type, %{table: table.name, key: "values, not filters"}},
      else: key_identity(grants, table, key)
  end

  defp identity(_grants, table, _params),
    do: {:error, :type, %{table: table.name, need: "id or key"}}

  defp key_identity(grants, table, key) do
    keys = table.naturals ++ table.uniques

    unique_cols =
      for c <- table.cols, c.unique, do: %{cols: [c.name], where: nil, where_term: nil}

    wanted = Enum.sort(Map.keys(key))

    # A partial key (places' iso2 is a country's) holds only where its where does.
    case Enum.find(keys ++ unique_cols, &(Enum.sort(&1.cols) == wanted)) do
      nil ->
        {:error, :natural_key,
         %{
           table: table.name,
           key: brief(Map.keys(key)),
           reason: "no declared key is made of exactly these columns",
           keys: Enum.map(keys ++ unique_cols, &Schema.key_doc/1)
         }}

      k ->
        with {:ok, d} <- filters(grants, table, key),
             do: {:ok, dynamic(^d and ^term(table, k.where_term))}
    end
  end

  defp term(_table, nil), do: dynamic(true)

  defp term(table, {:eq, col, value}) do
    f = String.to_atom(col)
    {:ok, v} = Ecto.Type.cast(Schema.cast_type(Schema.column(table.name, col)), value)
    dynamic([r], field(r, ^f) == ^v)
  end

  defp term(_table, {:null, col}), do: dynamic([r], is_nil(field(r, ^String.to_atom(col))))

  defp term(_table, {:not_null, col}),
    do: dynamic([r], not is_nil(field(r, ^String.to_atom(col))))

  defp id(id) when is_integer(id) and id > 0 and id <= @int64, do: {:ok, id}
  defp id(other), do: {:error, :type, %{param: "id", got: inspect(other)}}

  defp optional_id(nil), do: {:ok, nil}
  defp optional_id(id), do: id(id)

  defp bound(nil, default, _max), do: {:ok, default}
  defp bound(n, _default, max) when is_integer(n) and n > 0 and n <= max, do: {:ok, n}

  defp bound(n, _default, max) when is_integer(n) and n > max,
    do: {:error, :too_large, %{limit: n, max: max}}

  defp bound(other, _default, _max), do: {:error, :type, %{param: "limit", got: brief(other)}}

  defp bound(n, default, max, name) do
    case bound(n, default, max) do
      {:error, code, data} -> {:error, code, Map.put(data, :param, name)}
      ok -> ok
    end
  end

  defp non_negative(nil, default, _name), do: {:ok, default}

  defp non_negative(n, _default, _name) when is_integer(n) and n >= 0 and n <= @int64,
    do: {:ok, n}

  defp non_negative(other, _default, name),
    do: {:error, :type, %{param: name, got: inspect(other)}}

  # ------------------------------------------------------------------ filters

  defp scans?(where) when is_map(where),
    do: Enum.any?(where, fn {_, test} -> is_map(test) and Map.has_key?(test, "like") end)

  defp scans?(_), do: false

  defp filters(grants, table, where) when is_map(where) do
    Enum.reduce_while(where, {:ok, dynamic(true)}, fn {name, test}, {:ok, acc} ->
      with {:ok, col} <- column(grants, table, name),
           :ok <- filterable(table, col),
           {:ok, d} <- filter(col, test) do
        {:cont, {:ok, dynamic(^acc and ^d)}}
      else
        error -> {:halt, error}
      end
    end)
  end

  defp filters(_grants, table, other),
    do: {:error, :type, %{table: table.name, where: brief(other)}}

  defp filterable(table, col) do
    if col.deferred or col.type in [:json, :bytes],
      do: {:error, :column, %{table: table.name, column: col.name, reason: "not filterable"}},
      else: :ok
  end

  defp filter(col, test) when is_map(test) and map_size(test) == 1 do
    [{op, value}] = Map.to_list(test)
    f = String.to_atom(col.name)

    case {op, value} do
      {"eq", nil} ->
        {:ok, dynamic([r], is_nil(field(r, ^f)))}

      {"eq", v} ->
        cast(col, v, &dynamic([r], field(r, ^f) == ^&1))

      {"ne", nil} ->
        {:ok, dynamic([r], not is_nil(field(r, ^f)))}

      {"ne", v} ->
        cast(col, v, &dynamic([r], field(r, ^f) != ^&1 or is_nil(field(r, ^f))))

      {op, nil} when op in ~w(lt le gt ge) ->
        {:error, :type, %{column: col.name, filter: op, reason: "compares with null"}}

      {"lt", v} ->
        cast(col, v, &dynamic([r], field(r, ^f) < ^&1))

      {"le", v} ->
        cast(col, v, &dynamic([r], field(r, ^f) <= ^&1))

      {"gt", v} ->
        cast(col, v, &dynamic([r], field(r, ^f) > ^&1))

      {"ge", v} ->
        cast(col, v, &dynamic([r], field(r, ^f) >= ^&1))

      {"null", true} ->
        {:ok, dynamic([r], is_nil(field(r, ^f)))}

      {"null", false} ->
        {:ok, dynamic([r], not is_nil(field(r, ^f)))}

      {"in", vs} when is_list(vs) and length(vs) <= @find_max ->
        cast_list(col, vs, f)

      {op, s} when op in ~w(like prefix) and is_binary(s) and byte_size(s) > 1000 ->
        {:error, :too_large, %{column: col.name, filter: op, max: 1000}}

      {"like", s} when is_binary(s) and col.type in [:str, :text] ->
        {:ok, like(f, "%", s, "%")}

      {"prefix", s} when is_binary(s) and col.type in [:str, :text] ->
        {:ok, like(f, "", s, "%")}

      _ ->
        {:error, :type, %{column: col.name, filter: brief(test)}}
    end
  end

  defp filter(col, value) when not is_map(value), do: filter(col, %{"eq" => value})
  defp filter(col, test), do: {:error, :type, %{column: col.name, filter: brief(test)}}

  defp like(f, before, s, after_) do
    pattern = before <> String.replace(s, ~r/[\\%_]/, "\\\\\\0") <> after_
    dynamic([r], fragment("? LIKE ? ESCAPE '\\'", field(r, ^f), ^pattern))
  end

  defp cast(col, value, build) do
    with {:ok, v} <- safe_cast(col, value),
         true <- fits?(col, v) do
      {:ok, build.(v)}
    else
      _ -> {:error, :type, %{column: col.name, value: brief(value)}}
    end
  end

  # An integer filter beyond what its column can hold matches nothing a
  # database can compare, so it is refused before it reaches SQLite.
  defp fits?(%{type: t}, v) when t in [:id, :ref, :u32] and is_integer(v),
    do: v in 0..4_294_967_295

  defp fits?(%{type: :u8}, v) when is_integer(v), do: v in 0..255
  defp fits?(%{type: :i64}, v) when is_integer(v), do: v in -@int64..@int64
  defp fits?(_col, _v), do: true

  # Ecto's cast of a number too large for a float raises; any value that
  # will not cast is the caller's, never an exception.
  defp safe_cast(col, value) do
    Ecto.Type.cast(Schema.cast_type(col), value)
  rescue
    _ in [ArithmeticError, ArgumentError] -> :error
  end

  # A name the caller sent, as a refusal repeats it: 64 bytes at most.
  # Cut by bytes first: one grapheme can be any length.
  defp name_echo(name) when is_binary(name),
    do: name |> binary_part(0, min(64, byte_size(name))) |> trim_invalid()

  defp name_echo(name), do: brief(name)

  # A refusal names the value it refused, bounded.
  defp brief(value), do: inspect(value, limit: 8, printable_limit: 64)

  defp cast_list(col, values, f) do
    values
    |> Enum.reduce_while({:ok, []}, fn v, {:ok, acc} ->
      with {:ok, cast} <- safe_cast(col, v),
           true <- fits?(col, cast) do
        {:cont, {:ok, [cast | acc]}}
      else
        _ -> {:halt, {:error, :type, %{column: col.name, value: brief(v)}}}
      end
    end)
    |> case do
      {:ok, vs} -> {:ok, dynamic([r], field(r, ^f) in ^vs)}
      error -> error
    end
  end

  # ------------------------------------------------------------------ paging

  # Order by col, then id, nulls last in both directions. NULLS LAST, not an
  # IS NULL term: a descending page then walks an index on the column
  # backwards instead of sorting every row the filter keeps.
  defp order(query, %{name: "id"}, desc),
    do: order_by(query, [r], [{^dir(desc), r.id}])

  defp order(query, col, desc) do
    f = String.to_atom(col.name)
    nulls_last = if desc, do: :desc_nulls_last, else: :asc_nulls_last
    order_by(query, [r], [{^nulls_last, field(r, ^f)}, {^dir(desc), r.id}])
  end

  defp dir(true), do: :desc
  defp dir(false), do: :asc

  defp page(query, _order, _desc, nil), do: query

  defp page(query, %{name: "id"}, desc, [_, _, id]) do
    if desc, do: where(query, [r], r.id < ^id), else: where(query, [r], r.id > ^id)
  end

  defp page(query, col, desc, [null?, value, id]) do
    f = String.to_atom(col.name)

    cond do
      null? and desc -> where(query, [r], is_nil(field(r, ^f)) and r.id < ^id)
      null? -> where(query, [r], is_nil(field(r, ^f)) and r.id > ^id)
      true -> page_value(query, f, desc, cast_cursor(col, value), id)
    end
  end

  defp page_value(query, f, true, v, id),
    do:
      where(
        query,
        [r],
        is_nil(field(r, ^f)) or field(r, ^f) < ^v or (field(r, ^f) == ^v and r.id < ^id)
      )

  defp page_value(query, f, false, v, id),
    do:
      where(
        query,
        [r],
        is_nil(field(r, ^f)) or field(r, ^f) > ^v or (field(r, ^f) == ^v and r.id > ^id)
      )

  # A cursor carries a value of its order column; any other is tampered with.
  defp cast_cursor(col, value) do
    case safe_cast(col, value) do
      {:ok, v} when v == nil ->
        v

      {:ok, v} ->
        if fits?(col, v),
          do: v,
          else:
            raise(Ecto.Query.CastError,
              value: value,
              type: col.type,
              message: "a tampered cursor"
            )

      _ ->
        raise Ecto.Query.CastError, value: value, type: col.type, message: "a tampered cursor"
    end
  end

  defp cursor_after(row, order, _cols) do
    value = Map.get(row, String.to_atom(order.name))
    [is_nil(value), value, row.id] |> Jason.encode!() |> Base.url_encode64(padding: false)
  end

  defp decode_cursor(nil), do: {:ok, nil}

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, [null?, value, id] = c}
         when is_boolean(null?) and is_integer(id) and id >= 0 and id <= @int64 <-
           Jason.decode(json),
         true <- null? == is_nil(value) do
      {:ok, c}
    else
      _ -> {:error, :type, %{param: "after"}}
    end
  end

  defp decode_cursor(_), do: {:error, :type, %{param: "after"}}

  # ------------------------------------------------------------------ rows out

  # A deferred column comes back as its byte length and the first 8 bytes
  # (hex) of its stored hash twin: no text is read to answer a find or a
  # get. The order column is always selected so a cursor can be built from
  # the last row.
  defp select_map(table, cols) do
    Enum.reduce(cols, %{}, fn col, acc ->
      f = String.to_atom(col.name)

      if col.deferred do
        twin = Enum.find(table.cols, &(&1.sha_of == col.name))

        acc
        |> Map.put(f, dynamic([r], fragment("length(CAST(? AS BLOB))", field(r, ^f))))
        |> then(
          &if(twin,
            do: Map.put(&1, sha_key(col), dynamic([r], field(r, ^String.to_atom(twin.name)))),
            else: &1
          )
        )
      else
        Map.put(acc, f, dynamic([r], field(r, ^f)))
      end
    end)
  end

  defp sha_key(col), do: String.to_atom(col.name <> "__sha")

  defp out(row, cols) do
    Map.new(cols, fn col ->
      v = Map.get(row, String.to_atom(col.name))

      v =
        if not col.deferred or v == nil,
          do: v,
          else: %{"len" => v, "sha" => short(Map.get(row, sha_key(col)))}

      {col.name, v}
    end)
  end

  defp short(nil), do: nil
  defp short(hex), do: binary_part(hex, 0, min(16, byte_size(hex)))

  defp sha(nil), do: nil

  defp sha(text),
    do: :crypto.hash(:sha256, text) |> binary_part(0, 8) |> Base.encode16(case: :lower)

  defp run(account_id, fun) when is_integer(account_id), do: Repo.with_account(account_id, fun)
end
