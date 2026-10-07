defmodule Hireme.Mcp.Args do
  @moduledoc """
  Tool arguments off the wire, read once.

  Every reader returns `{:ok, value}` or `{:error, {:argument, name}}`.
  Nothing here raises on a bad frame.
  """

  alias Hireme.Pipeline

  @type problem :: {:argument, String.t()}

  @spec int(map(), String.t()) :: {:ok, integer()} | {:error, problem()}
  def int(args, name) do
    case Map.get(args, name) do
      n when is_integer(n) -> {:ok, n}
      s when is_binary(s) -> parse_int(s, name)
      _ -> {:error, {:argument, name}}
    end
  end

  @spec optional_int(map(), String.t()) :: {:ok, integer() | nil} | {:error, problem()}
  def optional_int(args, name) do
    case Map.get(args, name) do
      nil -> {:ok, nil}
      "" -> {:ok, nil}
      _ -> int(args, name)
    end
  end

  @spec string(map(), String.t()) :: {:ok, String.t()}
  def string(args, name) do
    case Map.get(args, name) do
      s when is_binary(s) -> {:ok, s}
      _ -> {:ok, ""}
    end
  end

  @spec optional_string(map(), String.t()) :: String.t() | nil
  def optional_string(args, name) do
    case Map.get(args, name) do
      s when is_binary(s) and s != "" -> s
      _ -> nil
    end
  end

  @spec score(map(), String.t()) :: {:ok, Hireme.LifeEv.score()} | {:error, problem()}
  def score(args, name) do
    case int(args, name) do
      {:ok, n} when n in 0..100 -> {:ok, n}
      _ -> {:error, {:argument, name}}
    end
  end

  @spec optional_score(map(), String.t(), Hireme.LifeEv.score()) ::
          {:ok, Hireme.LifeEv.score()} | {:error, problem()}
  def optional_score(args, name, default) do
    case optional_int(args, name) do
      {:ok, nil} -> {:ok, default}
      {:ok, n} when n in 0..100 -> {:ok, n}
      _ -> {:error, {:argument, name}}
    end
  end

  @spec stage(map(), String.t()) :: {:ok, Pipeline.stage()} | {:error, problem()}
  def stage(args, name) do
    case Pipeline.parse(Map.get(args, name)) do
      {:ok, stage} -> {:ok, stage}
      :error -> {:error, {:argument, name}}
    end
  end

  defp parse_int(s, name) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> {:error, {:argument, name}}
    end
  end
end

defmodule Hireme.Mcp do
  @moduledoc """
  Tool calls for a connected agent.

  The directory socket at `/mcp/websocket` only lists letterboxes.
  A letterbox socket at `/mcp/letterbox/:letterbox_id/websocket` is the
  full-duplex lease. Its handle reads and writes one application. The
  command carried to the consumer has no application id. A job id, a
  variant id, or a letterbox id in the arguments is checked against the
  handle and otherwise ignored.
  """

  alias Hireme.CvPair
  alias Hireme.Desk
  alias Hireme.Desk.Filters
  alias Hireme.Letterbox
  alias Hireme.Letterbox.Handle
  alias Hireme.Mcp.Args
  alias Hireme.LifeEv
  alias Hireme.Pipeline

  @type frame :: map()

  @spec directory(frame()) :: map()
  def directory(%{"id" => id, "method" => "tools/list"}) do
    %{id: id, result: %{tools: directory_tools()}}
  end

  def directory(%{"id" => id, "method" => "tools/call", "params" => %{"name" => name} = params}) do
    case directory_call(name, params["arguments"] || %{}) do
      {:ok, result} -> %{id: id, result: result}
      {:error, reason} -> %{id: id, error: %{code: -32000, message: error_message(reason)}}
    end
  end

  def directory(%{"id" => id}) do
    %{id: id, error: %{code: -32601, message: "unknown method"}}
  end

  def directory(_), do: %{error: %{code: -32600, message: "invalid request"}}

  @spec handle(Handle.t(), frame()) :: map()
  def handle(%Handle{}, %{"id" => id, "method" => "tools/list"}) do
    %{id: id, result: %{tools: leased_tools()}}
  end

  def handle(%Handle{} = handle, %{"id" => id, "method" => "tools/call", "params" => params}) do
    case call(handle, params["name"], params["arguments"] || %{}) do
      {:ok, result} -> %{id: id, result: result}
      {:error, reason} -> %{id: id, error: %{code: -32000, message: error_message(reason)}}
    end
  end

  def handle(%Handle{}, %{"id" => id}) do
    %{id: id, error: %{code: -32601, message: "unknown method"}}
  end

  def handle(%Handle{}, _), do: %{error: %{code: -32600, message: "invalid request"}}

  defp directory_call("list_letterboxes", args) do
    with {:ok, min} <- Args.optional_score(args, "min_score", 0) do
      rows =
        Letterbox.list()
        |> Enum.filter(&(&1.score_100 >= min))
        |> Enum.sort_by(&(-&1.score_100))
        |> Enum.map(&letterbox_row/1)

      {:ok, %{"letterboxes" => rows}}
    end
  end

  defp directory_call("list_batches", _args), do: {:ok, %{"batches" => batch_rows()}}

  # Cards come back in board order: score_100 high to low, then batch.
  defp directory_call("list_applications", args) do
    {:ok, %{"applications" => application_rows(list_filters(args))}}
  end

  # The keepers an agent would draft first. This ranks; it does not submit.
  defp directory_call("recommend_applications", args) do
    with {:ok, min} <- Args.optional_score(args, "min_score", 90),
         {:ok, limit} <- Args.optional_int(args, "limit") do
      limit = if is_integer(limit) and limit > 0, do: min(limit, 100), else: 25
      filters = Filters.merge(list_filters(args), %{min_score: min, status: :open})

      fire =
        if Enum.any?(Desk.list_batches(), &(&1.fire == :open_fire)), do: "open_fire", else: "hold"

      {:ok,
       %{
         "applications" => filters |> application_rows() |> Enum.take(limit),
         "min_score" => min,
         "fire" => fire,
         "note" => "Ranked by score_100. This tool does not submit."
       }}
    end
  end

  defp directory_call("score_distribution", args) do
    chart = LifeEv.chart(Desk.list_cards(list_filters(args)))

    {:ok,
     %{
       "n" => chart.n,
       "mean" => chart.mean,
       "max" => chart.max,
       "min" => chart.min,
       "bands" =>
         Enum.map(chart.bands, fn row ->
           %{
             "band" => LifeEv.name(row.key),
             "label" => row.label,
             "min" => row.min,
             "max" => row.max,
             "count" => row.count,
             "share" => row.share
           }
         end),
       "bins" => Enum.map(chart.bins, &%{"lo" => &1.lo, "hi" => &1.hi, "count" => &1.count})
     }}
  end

  defp directory_call(name, _args)
       when name in ~w(get_application set_stage set_next_action set_score tailor_line open_cv_generation) do
    {:error, :unleased}
  end

  defp directory_call(_name, _args), do: {:error, :unknown_tool}

  defp list_filters(args) do
    Filters.from_params(%{
      "q" => Args.optional_string(args, "q"),
      "stage" => Args.optional_string(args, "stage"),
      "status" => Args.optional_string(args, "status") || "all",
      "batch" => Args.optional_string(args, "batch"),
      "min_score" => Args.optional_string(args, "min_score") || Map.get(args, "min_score"),
      "band" => Args.optional_string(args, "band")
    })
  end

  defp application_rows(filters) do
    Enum.map(Desk.list_cards(filters), fn card ->
      %{
        "job_id" => card.id,
        "company" => card.company,
        "role" => card.role,
        "stage" => Pipeline.name(card.stage),
        "batch" => card.batch_code,
        "cv_label" => card.cv_label,
        "score_100" => card.score_100,
        "band" => LifeEv.name(LifeEv.band(card.score_100))
      }
    end)
  end

  @spec call(Handle.t(), String.t(), map()) :: {:ok, map()} | {:error, term()}
  def call(%Handle{} = handle, "get_application", args) do
    with :ok <- same_target(handle, args),
         {:ok, focus} <- Letterbox.command(handle, :get) do
      {:ok, application_view(handle, focus)}
    end
  end

  def call(%Handle{} = handle, "set_stage", args) do
    with :ok <- same_target(handle, args),
         {:ok, stage} <- Args.stage(args, "stage"),
         {:ok, job} <- Letterbox.command(handle, {:set_stage, stage}) do
      {:ok, %{"job_id" => job.id, "stage" => Pipeline.name(job.current_stage)}}
    end
  end

  def call(%Handle{} = handle, "set_next_action", args) do
    with :ok <- same_target(handle, args),
         {:ok, action} <- Args.string(args, "next_action"),
         {:ok, job} <- Letterbox.command(handle, {:set_next, action}) do
      {:ok, %{"job_id" => job.id, "next_action" => job.next_action}}
    end
  end

  def call(%Handle{} = handle, "set_score", args) do
    with :ok <- same_target(handle, args),
         {:ok, score} <- Args.score(args, "score"),
         {:ok, job} <- Letterbox.command(handle, {:set_score, score}) do
      {:ok,
       %{
         "job_id" => job.id,
         "score_100" => job.score_100,
         "band" => LifeEv.name(LifeEv.band(job.score_100))
       }}
    end
  end

  def call(%Handle{} = handle, "tailor_line", args) do
    with :ok <- same_target(handle, args),
         {:ok, item_id} <- Args.int(args, "item_id"),
         {:ok, pair} <- Letterbox.command(handle, {:tailor, item_id, tailor_attrs(args)}) do
      {:ok, %{"job_id" => CvPair.job_id(pair), "variant_id" => CvPair.variant_id(pair)}}
    end
  end

  def call(%Handle{} = handle, "open_cv_generation", args) do
    with :ok <- same_target(handle, args),
         {:ok, lineage} <- Letterbox.command(handle, :open_generation) do
      {:ok, %{"employer_id" => lineage.employer_id, "generation" => lineage.generation}}
    end
  end

  def call(%Handle{}, _name, _args), do: {:error, :unknown_tool}

  @bands Enum.map(LifeEv.keys(), &LifeEv.name/1)

  defp directory_tools do
    [
      tool(
        "list_letterboxes",
        "List letterbox ids, highest score_100 first. Lease one to open a duplex socket",
        %{"min_score" => %{"type" => "integer", "minimum" => 0, "maximum" => 100}}
      ),
      tool("list_batches", "List batches on the desk", %{}),
      tool(
        "list_applications",
        "List applications ranked by score_100, highest first",
        filter_schema()
      ),
      tool(
        "recommend_applications",
        "The top applications by score_100 (default floor 90) to draft first. Ranks only; does not submit",
        Map.put(filter_schema(), "limit", %{"type" => "integer", "minimum" => 1, "maximum" => 100})
      ),
      tool(
        "score_distribution",
        "score_100 band counts and ten-point bins for the filtered desk",
        filter_schema()
      )
    ]
  end

  defp filter_schema do
    %{
      "q" => %{"type" => "string"},
      "stage" => %{"type" => "string", "enum" => Enum.map(Pipeline.keys(), &Pipeline.name/1)},
      "status" => %{"type" => "string"},
      "batch" => %{"type" => "string"},
      "min_score" => %{"type" => "integer", "minimum" => 0, "maximum" => 100},
      "band" => %{"type" => "string", "enum" => @bands}
    }
  end

  defp leased_tools do
    [
      tool("get_application", "Read the application closed over by this lease", %{}),
      tool("set_stage", "Move this application along the battleplan", %{
        "stage" => %{"type" => "string", "enum" => Enum.map(Pipeline.keys(), &Pipeline.name/1)}
      }),
      tool("set_next_action", "Set the next action on this application", %{
        "next_action" => %{"type" => "string"}
      }),
      tool("set_score", "Set this application's score_100", %{
        "score" => %{"type" => "integer", "minimum" => 0, "maximum" => 100}
      }),
      tool("tailor_line", "Add or revise a line on the CV closed over by this lease", %{
        "item_id" => %{"type" => "integer"},
        "mode" => %{"type" => "string", "enum" => ~w(hidden altered emphasized)},
        "body" => %{"type" => "string"},
        "reason" => %{"type" => "string"}
      }),
      tool(
        "open_cv_generation",
        "After the cooldown, open an additive generation for this application's employer",
        %{}
      )
    ]
  end

  defp letterbox_row(row) do
    %{
      "letterbox_id" => row.id,
      "job_id" => row.job_id,
      "company" => row.company,
      "role" => row.role,
      "stage" => Pipeline.name(row.stage),
      "batch" => row.batch,
      "score_100" => row.score_100,
      "band" => LifeEv.name(LifeEv.band(row.score_100)),
      "leased" => row.leased,
      "socket" => "/mcp/letterbox/#{row.id}/websocket"
    }
  end

  defp batch_rows do
    Enum.map(Desk.list_batches(), fn batch ->
      %{
        "code" => batch.code,
        "fire" => Atom.to_string(batch.fire),
        "status" => Atom.to_string(batch.status),
        "ordinal" => batch.ordinal
      }
    end)
  end

  defp application_view(handle, focus) do
    pair = handle.pair

    %{
      "letterbox_id" => handle.id,
      "job_id" => CvPair.job_id(pair),
      "variant_id" => CvPair.variant_id(pair),
      "employer_id" => CvPair.employer_id(pair),
      "lineage_id" => CvPair.lineage_id(pair),
      "company" => focus.job.company,
      "role" => focus.job.role,
      "stage" => Pipeline.name(focus.job.current_stage),
      "score_100" => focus.job.score_100,
      "band" => LifeEv.name(LifeEv.band(focus.job.score_100)),
      "cv_label" => focus.variant.label,
      "lines" =>
        Enum.map(focus.masks, fn line ->
          %{"item_id" => line.id, "mode" => Atom.to_string(line.mode), "title" => line.title}
        end)
    }
  end

  defp tailor_attrs(args) do
    %{
      mode: Args.optional_string(args, "mode"),
      body: Args.optional_string(args, "body"),
      reason: Args.optional_string(args, "reason")
    }
  end

  defp same_target(handle, args) do
    pair = handle.pair

    with {:ok, job_id} <- Args.optional_int(args, "job_id"),
         {:ok, letterbox_id} <- Args.optional_int(args, "letterbox_id"),
         {:ok, variant_id} <- Args.optional_int(args, "variant_id"),
         {:ok, lineage_id} <- Args.optional_int(args, "lineage_id") do
      cond do
        mismatch?(job_id, CvPair.job_id(pair)) -> {:error, :letterbox_mismatch}
        mismatch?(letterbox_id, handle.id) -> {:error, :letterbox_mismatch}
        mismatch?(variant_id, CvPair.variant_id(pair)) -> {:error, :cv_mismatch}
        mismatch?(lineage_id, CvPair.lineage_id(pair)) -> {:error, :cv_mismatch}
        true -> :ok
      end
    end
  end

  defp mismatch?(nil, _expected), do: false
  defp mismatch?(value, expected), do: value != expected

  defp tool(name, description, schema) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{"type" => "object", "properties" => schema}
    }
  end

  defp error_message(%Ecto.Changeset{}), do: "invalid"
  defp error_message({:argument, name}), do: "bad argument #{name}"
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)
end
