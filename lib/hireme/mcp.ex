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

  The directory socket at `/mcp/websocket` lists, searches, and
  recommends applications. Ranking on that socket uses `score_100`
  (Life-EV, 0–100) as the primary signal. The same socket logs gym
  reps and networking entries (not CRM, not job submits). A letterbox
  socket at `/mcp/letterbox/:letterbox_id/websocket` is the full-duplex
  lease. Its handle reads and writes one application. The command
  carried to the consumer has no application id. A job id, a variant
  id, or a letterbox id in the arguments is checked against the handle
  and otherwise ignored. Neither socket submits an application.
  """

  alias Hireme.CvPair
  alias Hireme.Desk
  alias Hireme.Desk.Filters
  alias Hireme.Gym
  alias Hireme.Heat
  alias Hireme.Letterbox
  alias Hireme.Letterbox.Handle
  alias Hireme.Mcp.Args
  alias Hireme.Net
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

  defp directory_call("list_letterboxes", _args), do: {:ok, %{"letterboxes" => letterbox_rows()}}
  defp directory_call("list_batches", _args), do: {:ok, %{"batches" => batch_rows()}}

  defp directory_call("list_applications", args) do
    {:ok, %{"applications" => application_rows(list_filters(args))}}
  end

  defp directory_call("recommend_applications", args) do
    min_score =
      case Args.optional_int(args, "min_score") do
        {:ok, nil} -> 90
        {:ok, n} -> n
        {:error, _} -> 90
      end

    limit =
      case Args.optional_int(args, "limit") do
        {:ok, nil} -> 25
        {:ok, n} when n > 0 -> min(n, 100)
        _ -> 25
      end

    filters = Filters.merge(list_filters(args), %{min_score: min_score, status: :open})

    apps =
      filters
      |> application_rows()
      |> Enum.reject(&(&1["heat_state"] == "blocked"))
      |> Enum.take(limit)

    {:ok,
     %{
       "applications" => apps,
       "min_score" => min_score,
       "fire" => "hold",
       "note" =>
         "FIRE HOLD. Ranked by score_100 then cooler heat. Blocked (over cap) omitted. Does not submit."
     }}
  end

  defp directory_call("score_distribution", args) do
    chart = Hireme.LifeEv.chart(Desk.list_cards(list_filters(args)))

    {:ok,
     %{
       "n" => chart.n,
       "mean" => chart.mean,
       "max" => chart.max,
       "min" => chart.min,
       "bands" =>
         Enum.map(chart.bands, fn row ->
           %{
             "band" => Hireme.LifeEv.name(row.key),
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

  defp directory_call("heat_status", args) do
    chart = Heat.chart()
    company = Args.optional_string(args, "company")
    ats = Args.optional_string(args, "ats")

    {:ok,
     %{
       "companies" =>
         chart.companies
         |> maybe_filter_key(company)
         |> Enum.map(&heat_row_view/1),
       "vendors" =>
         chart.vendors
         |> maybe_filter_key(ats)
         |> Enum.map(&heat_row_view/1),
       "note" => "FIRE HOLD. Heat gates the queue. It does not submit."
     }}
  end

  defp directory_call("can_apply", args) do
    with {:ok, job_id} <- apply_id(args) do
      verdict = Heat.can_apply(job_id)

      {:ok,
       %{
         "job_id" => job_id,
         "decision" => Atom.to_string(verdict.decision),
         "reason" => Atom.to_string(verdict.reason),
         "company" => verdict.company,
         "company_load" => verdict.company_load,
         "company_cap" => verdict.company_cap,
         "company_increment" => verdict.company_increment,
         "size" => Hireme.Heat.Org.name(verdict.size),
         "ats_vendor" => Hireme.Heat.Ats.name(verdict.ats_vendor),
         "ats_tenant" => verdict.ats_tenant,
         "vendor_load" => verdict.vendor_load,
         "vendor_cap" => verdict.vendor_cap,
         "tenant_load" => verdict.tenant_load,
         "tenant_cap" => verdict.tenant_cap,
         "cooldown_days" => verdict.cooldown_days,
         "note" => verdict.note,
         "fire" => "hold"
       }}
    end
  end

  defp directory_call("gym_status", _args), do: {:ok, gym_progress_view(Gym.progress())}

  defp directory_call("gym_log", args) do
    case Gym.log(args) do
      {:ok, rep} ->
        {:ok, Map.put(gym_rep_view(rep), "progress", gym_progress_view(Gym.progress()))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp directory_call("gym_set_target", args) do
    with {:ok, n} <- Args.int(args, "target"),
         {:ok, n} <- Gym.set_target(n) do
      {:ok, gym_progress_view(Gym.progress()) |> Map.put("target", n)}
    end
  end

  defp directory_call("net_status", _args), do: {:ok, net_progress_view(Net.progress())}

  defp directory_call("net_log", args) do
    case Net.log(args) do
      {:ok, entry} ->
        {:ok, Map.put(net_entry_view(entry), "progress", net_progress_view(Net.progress()))}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp directory_call("net_set_lane", args) do
    with {:ok, url} <- Args.string(args, "url"),
         {:ok, _lane} <- Net.set_lane(url) do
      {:ok, net_progress_view(Net.progress())}
    end
  end

  defp directory_call(name, _args)
       when name in ~w(get_application set_stage set_next_action tailor_line open_cv_generation) do
    {:error, :unleased}
  end

  defp directory_call(_name, _args), do: {:error, :unknown_tool}

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

  defp directory_tools do
    [
      tool(
        "list_letterboxes",
        "List letterbox ids ranked by score_100 (Life-EV, 0–100, higher first). Lease one to open a duplex socket. FIRE HOLD — listing does not submit.",
        %{}
      ),
      tool("list_batches", "List batches on the desk", %{}),
      tool(
        "list_applications",
        "Search applications ranked by score_100 (Life-EV, 0–100) as the primary signal, then cooler company heat, then batch. Filters: q, stage, status, batch, band, min_score, heat (cool|warm|hot|blocked). FIRE HOLD — does not submit.",
        %{
          "q" => %{"type" => "string"},
          "stage" => %{"type" => "string", "enum" => Enum.map(Pipeline.keys(), &Pipeline.name/1)},
          "status" => %{"type" => "string"},
          "batch" => %{"type" => "string"},
          "band" => %{
            "type" => "string",
            "enum" => ["all" | Enum.map(Hireme.LifeEv.keys(), &Hireme.LifeEv.name/1)]
          },
          "min_score" => %{"type" => "integer", "minimum" => 0, "maximum" => 100},
          "heat" => %{"type" => "string", "enum" => ~w(all cool warm hot blocked)}
        }
      ),
      tool(
        "recommend_applications",
        "Recommend high Life-EV keepers. Primary ranking signal is score_100, then cooler heat. Omits heat-blocked roles. Default min_score 90. FIRE HOLD — never submits.",
        %{
          "q" => %{"type" => "string"},
          "stage" => %{"type" => "string", "enum" => Enum.map(Pipeline.keys(), &Pipeline.name/1)},
          "status" => %{"type" => "string"},
          "batch" => %{"type" => "string"},
          "band" => %{
            "type" => "string",
            "enum" => ["all" | Enum.map(Hireme.LifeEv.keys(), &Hireme.LifeEv.name/1)]
          },
          "min_score" => %{"type" => "integer", "minimum" => 0, "maximum" => 100},
          "limit" => %{"type" => "integer", "minimum" => 1, "maximum" => 100},
          "heat" => %{"type" => "string", "enum" => ~w(all cool warm hot blocked)}
        }
      ),
      tool(
        "score_distribution",
        "Histogram and band breakdown of score_100 (Life-EV) for the current filter. Primary ranking signal for list/recommend. FIRE HOLD — read only.",
        %{
          "q" => %{"type" => "string"},
          "stage" => %{"type" => "string", "enum" => Enum.map(Pipeline.keys(), &Pipeline.name/1)},
          "status" => %{"type" => "string"},
          "batch" => %{"type" => "string"},
          "band" => %{
            "type" => "string",
            "enum" => ["all" | Enum.map(Hireme.LifeEv.keys(), &Hireme.LifeEv.name/1)]
          },
          "min_score" => %{"type" => "integer", "minimum" => 0, "maximum" => 100},
          "heat" => %{"type" => "string", "enum" => ~w(all cool warm hot blocked)}
        }
      ),
      tool(
        "heat_status",
        "Company and ATS heat vs cap, with cooldown ETA. Optional company or ats filter. Structural governor — does not submit. FIRE HOLD.",
        %{
          "company" => %{"type" => "string"},
          "ats" => %{
            "type" => "string",
            "description" => "ATS vendor name (greenhouse, workday, …)"
          }
        }
      ),
      tool(
        "can_apply",
        "Would queueing this application (job_id / role_id) exceed company or ATS heat? Returns allow or defer with reason and cooldown. FIRE HOLD — does not submit.",
        %{
          "job_id" => %{"type" => "integer"},
          "role_id" => %{"type" => "integer"}
        }
      ),
      tool(
        "gym_status",
        "Gym conditioning progress: daily target, streak, weekly pace score (not Life-EV score_100), topic counts. Jumping jacks for the fight. FIRE HOLD — does not submit jobs.",
        %{}
      ),
      tool(
        "gym_log",
        "Log a LeetCode / Codeforces / systems rep. Upserts the problem by platform+slug. Conditioning, not the job. FIRE HOLD — does not submit jobs.",
        %{
          "platform" => %{"type" => "string", "enum" => Enum.map(Gym.platforms(), &Gym.name/1)},
          "title" => %{"type" => "string"},
          "slug" => %{"type" => "string"},
          "topic" => %{"type" => "string", "enum" => Enum.map(Gym.topics(), &Gym.name/1)},
          "difficulty" => %{
            "type" => "string",
            "enum" => Enum.map(Gym.difficulties(), &Gym.name/1)
          },
          "url" => %{"type" => "string"},
          "outcome" => %{"type" => "string", "enum" => Enum.map(Gym.outcomes(), &Gym.name/1)},
          "minutes" => %{"type" => "integer", "minimum" => 0},
          "note" => %{"type" => "string"},
          "done_on" => %{"type" => "string", "description" => "ISO date. Defaults to today."}
        }
      ),
      tool(
        "gym_set_target",
        "Set the gym daily solved-rep target (1–30). Conditioning pace, not Life-EV. FIRE HOLD.",
        %{"target" => %{"type" => "integer", "minimum" => 1, "maximum" => 30}}
      ),
      tool(
        "net_status",
        "Networking lane: Broadside Observer URL, shipped posts/artifacts this week, open drafts, observer runs. Not CRM. FIRE HOLD — does not submit jobs.",
        %{}
      ),
      tool(
        "net_log",
        "Log a Broadside Observer run, shipped artifact, X/social post, or outreach draft. Not a CRM. No contacts, no sequences. FIRE HOLD — does not submit jobs.",
        %{
          "kind" => %{"type" => "string", "enum" => Enum.map(Net.kinds(), &Net.name/1)},
          "channel" => %{"type" => "string", "enum" => Enum.map(Net.channels(), &Net.name/1)},
          "title" => %{"type" => "string"},
          "url" => %{"type" => "string"},
          "body" => %{"type" => "string"},
          "shipped_on" => %{
            "type" => "string",
            "description" => "ISO date. Defaults to today except drafts."
          }
        }
      ),
      tool(
        "net_set_lane",
        "Set the Broadside Observer research lane URL. Not CRM. FIRE HOLD.",
        %{"url" => %{"type" => "string"}}
      )
    ]
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

  defp letterbox_rows do
    Enum.map(Letterbox.list(), fn row ->
      %{
        "letterbox_id" => row.id,
        "job_id" => row.job_id,
        "company" => row.company,
        "role" => row.role,
        "stage" => Pipeline.name(row.stage),
        "batch" => row.batch,
        "score_100" => row.score_100,
        "band" => Hireme.LifeEv.name(row.band),
        "leased" => row.leased,
        "socket" => "/mcp/letterbox/#{row.id}/websocket"
      }
    end)
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
      "letterbox_id" => Letterbox.id(handle),
      "job_id" => CvPair.job_id(pair),
      "variant_id" => CvPair.variant_id(pair),
      "employer_id" => CvPair.employer_id(pair),
      "lineage_id" => CvPair.lineage_id(pair),
      "company" => focus.job.company,
      "role" => focus.job.role,
      "stage" => Pipeline.name(focus.job.current_stage),
      "score_100" => focus.job.score_100,
      "band" => Hireme.LifeEv.name(Hireme.LifeEv.band(focus.job.score_100)),
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
        mismatch?(letterbox_id, Letterbox.id(handle)) -> {:error, :letterbox_mismatch}
        mismatch?(variant_id, CvPair.variant_id(pair)) -> {:error, :cv_mismatch}
        mismatch?(lineage_id, CvPair.lineage_id(pair)) -> {:error, :cv_mismatch}
        true -> :ok
      end
    end
  end

  defp mismatch?(nil, _expected), do: false
  defp mismatch?(value, expected), do: value != expected

  defp list_filters(args) do
    min =
      case Args.optional_int(args, "min_score") do
        {:ok, n} -> n
        _ -> nil
      end

    Filters.from_params(%{
      "q" => Args.optional_string(args, "q"),
      "stage" => Args.optional_string(args, "stage"),
      "status" => Args.optional_string(args, "status") || "all",
      "batch" => Args.optional_string(args, "batch"),
      "band" => Args.optional_string(args, "band"),
      "min_score" => if(min, do: Integer.to_string(min), else: nil),
      "heat" => Args.optional_string(args, "heat")
    })
  end

  defp application_rows(%Filters{} = filters) do
    Enum.map(Desk.list_cards(filters), fn card ->
      %{
        "job_id" => card.id,
        "company" => card.company,
        "role" => card.role,
        "stage" => Pipeline.name(card.stage),
        "batch" => card.batch_code,
        "cv_label" => card.cv_label,
        "score_100" => card.score_100,
        "band" => Hireme.LifeEv.name(card.band),
        "load" => card.load,
        "cap" => card.cap,
        "heat_state" => Heat.state_name(card.heat_state),
        "ats" => Hireme.Heat.Ats.name(card.ats_vendor),
        "cooldown_days" => card.cooldown_days
      }
    end)
  end

  defp apply_id(args) do
    case Args.optional_int(args, "job_id") do
      {:ok, n} when is_integer(n) ->
        {:ok, n}

      _ ->
        case Args.optional_int(args, "role_id") do
          {:ok, n} when is_integer(n) -> {:ok, n}
          _ -> {:error, {:argument, "job_id"}}
        end
    end
  end

  defp maybe_filter_key(rows, nil), do: rows
  defp maybe_filter_key(rows, ""), do: rows

  defp maybe_filter_key(rows, needle) do
    n = String.downcase(needle)

    Enum.filter(
      rows,
      &(String.contains?(String.downcase(&1.key), n) or
          String.contains?(String.downcase(&1.label), n))
    )
  end

  defp heat_row_view(row) do
    %{
      "key" => row.key,
      "label" => row.label,
      "load" => row.load,
      "cap" => row.cap,
      "ratio" => row.ratio,
      "n" => row.n,
      "cooldown_days" => row.cooldown_days,
      "size" => row.size && Atom.to_string(row.size)
    }
  end

  defp gym_progress_view(%Gym.Progress{} = progress) do
    %{
      "today" => Date.to_iso8601(progress.today),
      "target" => progress.target,
      "streak" => progress.streak,
      "solved_today" => progress.solved_today,
      "solved_week" => progress.solved_week,
      "score" => progress.score,
      "note" =>
        "Gym score is weekly conditioning pace (0–100), not Life-EV score_100. FIRE HOLD — does not submit.",
      "topics" =>
        Enum.map(progress.topics, fn row ->
          %{"topic" => Gym.name(row.key), "label" => row.label, "count" => row.count}
        end),
      "recent" => Enum.map(progress.recent, &gym_rep_view/1)
    }
  end

  defp gym_rep_view(%Gym.Rep{} = rep) do
    problem = rep.problem

    %{
      "id" => rep.id,
      "done_on" => Date.to_iso8601(rep.done_on),
      "outcome" => Gym.name(rep.outcome),
      "minutes" => rep.minutes,
      "note" => rep.note,
      "platform" => Gym.name(problem.platform),
      "slug" => problem.slug,
      "title" => problem.title,
      "topic" => Gym.name(problem.topic),
      "difficulty" => Gym.name(problem.difficulty),
      "url" => problem.url
    }
  end

  defp net_progress_view(%Net.Progress{} = progress) do
    %{
      "lane" => progress.lane,
      "shipped_week" => progress.shipped_week,
      "drafts" => progress.drafts,
      "observer_runs" => progress.observer_runs,
      "note" => "Not CRM. Broadside Observer + shipped work. FIRE HOLD — does not submit.",
      "recent" => Enum.map(progress.recent, &net_entry_view/1)
    }
  end

  defp net_entry_view(%Net.Entry{} = entry) do
    %{
      "id" => entry.id,
      "kind" => Net.name(entry.kind),
      "channel" => Net.name(entry.channel),
      "title" => entry.title,
      "url" => entry.url,
      "body" => entry.body,
      "shipped_on" => entry.shipped_on && Date.to_iso8601(entry.shipped_on)
    }
  end

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
