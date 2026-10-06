defmodule Hireme.McpTest do
  use Hireme.DataCase, async: false

  alias Hireme.Corpus
  alias Hireme.Desk
  alias Hireme.Desk.Signal
  alias Hireme.Letterbox
  alias Hireme.Mcp
  alias HiremeWeb.McpDirectorySocket
  alias HiremeWeb.McpSocket

  test "a leased handle tailors its application and rejects a foreign variant" do
    %{job: job, item: item, letterbox_id: letterbox_id} = opened()
    {:ok, handle} = Letterbox.lease(letterbox_id, self())

    listed = Mcp.handle(handle, %{"id" => 1, "method" => "tools/list"})
    assert Enum.any?(listed.result.tools, &(&1["name"] == "tailor_line"))

    mismatch =
      Mcp.handle(handle, %{
        "id" => 2,
        "method" => "tools/call",
        "params" => %{
          "name" => "tailor_line",
          "arguments" => %{"variant_id" => -1, "item_id" => item.id, "mode" => "emphasized"}
        }
      })

    assert mismatch.error.message == "cv_mismatch"

    ok =
      Mcp.handle(handle, %{
        "id" => 3,
        "method" => "tools/call",
        "params" => %{
          "name" => "tailor_line",
          "arguments" => %{"item_id" => item.id, "mode" => "emphasized"}
        }
      })

    assert ok.result["job_id"] == job.id

    moved =
      Mcp.handle(handle, %{
        "id" => 4,
        "method" => "tools/call",
        "params" => %{"name" => "set_stage", "arguments" => %{"stage" => "gated"}}
      })

    assert moved.result == %{"job_id" => job.id, "stage" => "gated"}

    bad =
      Mcp.handle(handle, %{
        "id" => 5,
        "method" => "tools/call",
        "params" => %{"name" => "set_stage", "arguments" => %{"stage" => "sent"}}
      })

    assert bad.error.message == "bad argument stage"

    not_int =
      Mcp.handle(handle, %{
        "id" => 6,
        "method" => "tools/call",
        "params" => %{"name" => "tailor_line", "arguments" => %{"item_id" => "x"}}
      })

    assert not_int.error.message == "bad argument item_id"
    assert Letterbox.release(handle) == :ok
  end

  test "the directory socket lists letterboxes and refuses writes" do
    %{letterbox_id: letterbox_id} = opened()
    {:ok, state} = McpDirectorySocket.init(%{})

    {:reply, :ok, {:text, listed}, state} =
      McpDirectorySocket.handle_in({~s({"id": 1, "method": "tools/list"}), []}, state)

    assert Jason.decode!(listed)["id"] == 1

    {:reply, :ok, {:text, rows}, state} =
      McpDirectorySocket.handle_in(
        {~s({"id": 2, "method": "tools/call", "params": {"name": "list_letterboxes"}}), []},
        state
      )

    decoded = Jason.decode!(rows)
    assert Enum.any?(decoded["result"]["letterboxes"], &(&1["letterbox_id"] == letterbox_id))

    {:reply, :ok, {:text, refused}, _state} =
      McpDirectorySocket.handle_in(
        {~s({"id": 3, "method": "tools/call", "params": {"name": "tailor_line", "arguments": {}}}),
         []},
        state
      )

    assert Jason.decode!(refused)["error"]["message"] == "unleased"
  end

  test "the letterbox socket answers a call and pushes only its own notification" do
    %{job: job, letterbox_id: letterbox_id} = opened()
    {:ok, state} = McpSocket.init(%{id: letterbox_id})

    {:reply, :ok, {:text, payload}, state} =
      McpSocket.handle_in({~s({"id": 7, "method": "tools/list"}), []}, state)

    assert Jason.decode!(payload)["id"] == 7

    Phoenix.PubSub.broadcast(
      Hireme.PubSub,
      Desk.topic(),
      {:desk_event, Signal.stage(job.id, :gated)}
    )

    assert_receive {:desk_event, %Signal{} = signal}
    {:push, {:text, note}, state} = McpSocket.handle_info({:desk_event, signal}, state)
    decoded = Jason.decode!(note)
    assert decoded["method"] == "notifications/desk"
    assert decoded["params"] == %{"type" => "stage", "job_id" => job.id, "stage" => "gated"}

    Phoenix.PubSub.broadcast(
      Hireme.PubSub,
      Desk.topic(),
      {:desk_event, Signal.stage(-1, :gated)}
    )

    refute_receive {:desk_event, _}, 50
    assert McpSocket.terminate(:normal, state) == :ok
  end

  test "a second connection cannot lease the same letterbox" do
    %{letterbox_id: letterbox_id} = opened()
    {:ok, _state} = McpSocket.init(%{id: letterbox_id})

    task =
      Task.async(fn ->
        McpSocket.init(%{id: letterbox_id})
      end)

    assert {:stop, :busy, %{}} = Task.await(task)
  end

  defp opened do
    profile =
      Corpus.create_profile!(%{
        slug: "candidate-#{System.unique_integer([:positive])}",
        name: "Sample Candidate",
        headline: "Engineer",
        summary: "A sample profile."
      })

    item =
      Corpus.create_item!(%{
        profile_id: profile.id,
        kind: :experience,
        key: "exp.mcp.#{System.unique_integer([:positive])}",
        title: "Line",
        body: "Root",
        position: 1
      })

    job =
      Desk.create_job!(%{
        profile_id: profile.id,
        company: "Batch Co #{System.unique_integer([:positive])}",
        role: "Engineer",
        stage: "discovered",
        canonical_url: "https://jobs.example.test/#{System.unique_integer([:positive])}"
      })

    %{job: job, item: item, letterbox_id: Letterbox.for_job(job.id).id}
  end
end
