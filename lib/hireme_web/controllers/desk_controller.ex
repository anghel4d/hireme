defmodule HiremeWeb.DeskController do
  @moduledoc """
  The desk over HTTP: one columnar packet for the board, JSON for what
  is opened, and the human's writes. Refusals map to status codes; the
  body always says why.
  """

  use Phoenix.Controller, formats: [:json]
  import Plug.Conn

  alias Hireme.Campaign
  alias Hireme.Desk
  alias Hireme.Desk.Overlay
  alias Hireme.Desk.Packet
  alias Hireme.Narrative
  alias Hireme.Pipeline
  alias Hireme.Repo
  alias HiremeWeb.DeskJSON

  def pack(conn, _params) do
    conn
    |> put_resp_content_type("application/vnd.hireme.desk-packet", nil)
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, Packet.build())
  end

  def scoreboard(conn, _params), do: json(conn, DeskJSON.scoreboard(Campaign.scoreboard()))

  def focus(conn, %{"id" => id}) do
    with {:ok, id} <- int(id),
         %Desk.Focus{} = focus <- Desk.focus(id) do
      json(conn, DeskJSON.focus(focus))
    else
      _ -> refuse(conn, :not_found)
    end
  end

  def root(conn, %{"id" => id}) do
    with {:ok, id} <- int(id) do
      json(conn, DeskJSON.root(Desk.root(id)))
    else
      _ -> refuse(conn, :not_found)
    end
  end

  def set_stage(conn, %{"id" => id, "stage" => stage}) do
    with {:ok, id} <- int(id),
         {:ok, stage} <- Pipeline.parse(stage) |> or_argument("stage"),
         {:ok, _} <- Desk.set_stage(id, stage) do
      reply_focus(conn, id)
    else
      {:error, reason} -> refuse(conn, reason)
      :error -> refuse(conn, :not_found)
    end
  end

  def set_next(conn, %{"id" => id} = params) do
    due =
      case Date.from_iso8601(params["next_due"] || "") do
        {:ok, d} -> d
        _ -> nil
      end

    with {:ok, id} <- int(id),
         {:ok, _} <- Desk.set_next(id, String.trim(params["next_action"] || ""), due) do
      reply_focus(conn, id)
    else
      {:error, reason} -> refuse(conn, reason)
      :error -> refuse(conn, :not_found)
    end
  end

  def set_note(conn, %{"id" => id, "stage" => stage, "note" => note}) do
    with {:ok, id} <- int(id),
         {:ok, stage} <- Pipeline.parse(stage) |> or_argument("stage"),
         {:ok, _} <- Desk.set_note(id, stage, note || "") do
      reply_focus(conn, id)
    else
      {:error, reason} -> refuse(conn, reason)
      :error -> refuse(conn, :not_found)
    end
  end

  def set_score(conn, %{"id" => id, "score" => score}) do
    with {:ok, id} <- int(id),
         {:ok, score} when score in 0..100 <- int(score) |> or_argument("score"),
         {:ok, _} <- Desk.set_score(id, score) do
      reply_focus(conn, id)
    else
      {:ok, _} -> refuse(conn, {:argument, "score"})
      {:error, reason} -> refuse(conn, reason)
      :error -> refuse(conn, :not_found)
    end
  end

  def put_overlay(conn, %{"id" => id, "item_id" => item_id, "mode" => mode} = params) do
    with {:ok, id} <- int(id),
         {:ok, item_id} <- int(item_id) |> or_argument("item_id"),
         {:ok, change} <- overlay_change(mode, params),
         {:ok, _} <- Desk.put_overlay(id, item_id, change) do
      reply_focus(conn, id)
    else
      {:error, reason} -> refuse(conn, reason)
      :error -> refuse(conn, :not_found)
    end
  end

  def name_open_fire(conn, %{"code" => code}) do
    case Desk.name_open_fire(code) do
      {:ok, batch} -> json(conn, %{ok: true, batch: %{code: batch.code, fire: batch.fire}})
      {:error, reason} -> refuse(conn, reason)
    end
  end

  def save_narrative(conn, %{"id" => id, "body" => body}) when is_binary(body) do
    with {:ok, id} <- int(id),
         %Hireme.Corpus.Narrative{} = row <- Repo.get(Hireme.Corpus.Narrative, id) do
      saved = Narrative.update!(row, body)

      json(conn, %{ok: true, narrative: %{id: saved.id, body: saved.body, version: saved.version}})
    else
      _ -> refuse(conn, :not_found)
    end
  end

  defp overlay_change("inherit", _params), do: {:ok, :inherit}

  defp overlay_change(mode, params) do
    case Overlay.parse_mode(mode) do
      {:ok, :altered} ->
        case String.trim(params["body"] || "") do
          "" -> {:error, {:argument, "body"}}
          body -> {:ok, %{mode: :altered, body: body, reason: blank(params["reason"])}}
        end

      {:ok, :hidden} ->
        {:ok, %{mode: :hidden, reason: params["reason"] || "Hidden from this CV"}}

      {:ok, :emphasized} ->
        {:ok, %{mode: :emphasized, reason: params["reason"] || "Emphasized for this CV"}}

      :error ->
        {:error, {:argument, "mode"}}
    end
  end

  defp reply_focus(conn, id) do
    case Desk.focus(id) do
      nil -> refuse(conn, :not_found)
      focus -> json(conn, %{ok: true, focus: DeskJSON.focus(focus)})
    end
  end

  defp refuse(conn, reason) do
    {status, message} =
      case reason do
        :not_found -> {404, "not found"}
        :fire_hold -> {409, "fire_hold"}
        :heat -> {409, "heat"}
        :leased -> {423, "leased"}
        :cooldown -> {409, "cooldown"}
        :not_additive -> {409, "not_additive"}
        :batch -> {404, "batch"}
        {:argument, name} -> {400, "bad argument #{name}"}
        %Ecto.Changeset{} -> {422, "invalid"}
        other when is_atom(other) -> {409, Atom.to_string(other)}
        other -> {400, inspect(other)}
      end

    conn |> put_status(status) |> json(%{error: message})
  end

  defp or_argument({:ok, v}, _name), do: {:ok, v}
  defp or_argument(_, name), do: {:error, {:argument, name}}

  defp int(n) when is_integer(n), do: {:ok, n}

  defp int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, ""} -> {:ok, n}
      _ -> :error
    end
  end

  defp int(_), do: :error

  defp blank(nil), do: nil

  defp blank(text) do
    case String.trim(text) do
      "" -> nil
      t -> t
    end
  end
end
