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
  alias Hireme.Letterbox
  alias Hireme.Letterbox.Handle

  def directory(%{"id" => id, "method" => "tools/list"}) do
    %{id: id, result: %{tools: directory_tools()}}
  end

  def directory(%{
        "id" => id,
        "method" => "tools/call",
        "params" => %{"name" => "list_letterboxes"}
      }) do
    %{id: id, result: %{"letterboxes" => letterbox_rows()}}
  end

  def directory(%{"id" => id, "method" => "tools/call", "params" => %{"name" => "list_batches"}}) do
    {:ok, result} = Desk.list_batches() |> batches_result()
    %{id: id, result: result}
  end

  def directory(%{"id" => id, "method" => "tools/call"}) do
    %{id: id, error: %{code: -32000, message: "unleased"}}
  end

  def directory(%{"id" => id}) do
    %{id: id, error: %{code: -32601, message: "unknown method"}}
  end

  def directory(_), do: %{error: %{code: -32600, message: "invalid request"}}

  def handle(%Handle{}, %{"id" => id, "method" => "tools/list"}) do
    %{id: id, result: %{tools: leased_tools()}}
  end

  def handle(%Handle{} = handle, %{"id" => id, "method" => "tools/call", "params" => params}) do
    name = params["name"]
    args = params["arguments"] || %{}

    case call(handle, name, args) do
      {:ok, result} -> %{id: id, result: result}
      {:error, reason} -> %{id: id, error: %{code: -32000, message: error_message(reason)}}
    end
  end

  def handle(%Handle{}, %{"id" => id}) do
    %{id: id, error: %{code: -32601, message: "unknown method"}}
  end

  def handle(%Handle{}, _), do: %{error: %{code: -32600, message: "invalid request"}}

  def call(%Handle{} = handle, "get_application", args) do
    with :ok <- same_target(handle, args),
         {:ok, focus} <- Letterbox.command(handle, :get) do
      {:ok, application_view(handle, focus)}
    end
  end

  def call(%Handle{} = handle, "set_stage", args) do
    with :ok <- same_target(handle, args),
         {:ok, job} <- Letterbox.command(handle, {:set_stage, args["stage"] || ""}) do
      {:ok, %{"job_id" => job.id, "stage" => job.current_stage}}
    end
  end

  def call(%Handle{} = handle, "set_next_action", args) do
    with :ok <- same_target(handle, args),
         {:ok, job} <- Letterbox.command(handle, {:set_next, args["next_action"] || ""}) do
      {:ok, %{"job_id" => job.id, "next_action" => job.next_action}}
    end
  end

  def call(%Handle{} = handle, "tailor_line", args) do
    with :ok <- same_target(handle, args),
         {:ok, result} <-
           Letterbox.command(handle, {:tailor, int!(args["item_id"]), tailor_attrs(args)}) do
      {:ok, result}
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
      tool("list_letterboxes", "List letterbox ids. Lease one to open a duplex socket", %{}),
      tool("list_batches", "List batches on the desk", %{})
    ]
  end

  defp leased_tools do
    [
      tool("get_application", "Read the application closed over by this lease", %{}),
      tool("set_stage", "Move this application along the battleplan", %{
        "stage" => %{"type" => "string"}
      }),
      tool("set_next_action", "Set the next action on this application", %{
        "next_action" => %{"type" => "string"}
      }),
      tool("tailor_line", "Add or revise a line on the CV closed over by this lease", %{
        "item_id" => %{"type" => "integer"},
        "mode" => %{"type" => "string"},
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
        "stage" => row.stage,
        "batch" => row.batch,
        "leased" => row.leased,
        "socket" => "/mcp/letterbox/#{row.id}/websocket"
      }
    end)
  end

  defp batches_result(batches) do
    rows =
      Enum.map(batches, fn batch ->
        %{
          "code" => batch.code,
          "fire" => Atom.to_string(batch.fire),
          "status" => Atom.to_string(batch.status),
          "ordinal" => batch.ordinal
        }
      end)

    {:ok, %{"batches" => rows}}
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
      "stage" => focus.job.current_stage,
      "cv_label" => focus.variant.label,
      "lines" =>
        Enum.map(focus.masks, fn line ->
          %{"item_id" => line.id, "mode" => Atom.to_string(line.mode), "title" => line.title}
        end)
    }
  end

  defp tailor_attrs(args) do
    %{mode: args["mode"], body: args["body"], reason: args["reason"]}
  end

  defp same_target(handle, args) do
    pair = handle.pair

    cond do
      mismatch?(args["job_id"], CvPair.job_id(pair)) ->
        {:error, :letterbox_mismatch}

      mismatch?(args["letterbox_id"], Letterbox.id(handle)) ->
        {:error, :letterbox_mismatch}

      mismatch?(args["variant_id"], CvPair.variant_id(pair)) ->
        {:error, :cv_mismatch}

      mismatch?(args["lineage_id"], CvPair.lineage_id(pair)) ->
        {:error, :cv_mismatch}

      true ->
        :ok
    end
  end

  defp mismatch?(nil, _expected), do: false
  defp mismatch?("", _expected), do: false
  defp mismatch?(value, expected), do: int!(value) != expected

  defp tool(name, description, schema) do
    %{
      "name" => name,
      "description" => description,
      "inputSchema" => %{"type" => "object", "properties" => schema}
    }
  end

  defp int!(n) when is_integer(n), do: n

  defp int!(n) when is_binary(n) do
    case Integer.parse(n) do
      {value, ""} -> value
      _ -> raise ArgumentError, "expected an integer"
    end
  end

  defp error_message(%Ecto.Changeset{}), do: "invalid"
  defp error_message(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_message(reason), do: inspect(reason)
end
