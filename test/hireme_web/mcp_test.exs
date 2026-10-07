defmodule HiremeWeb.McpTest do
  use Hireme.DataCase, async: false
  import Hireme.Fixtures

  alias Hireme.Desk
  alias Hireme.Desk.Signal
  alias Hireme.Letterbox
  alias HiremeWeb.Mcp
  alias HiremeWeb.McpDirectorySocket
  alias HiremeWeb.McpSocket

  test "a leased handle tailors its application and rejects a foreign variant" do
    %{job: job, item: item, letterbox_id: letterbox_id} = opened()
    {:ok, handle} = Letterbox.lease(letterbox_id, self())

    listed = Mcp.handle(handle, %{"id" => 1, "method" => "tools/list"})
    assert Enum.any?(listed.result.tools, &(&1["name"] == "tailor_line"))

    mismatch =
      tool_call(handle, "tailor_line", %{
        "variant_id" => -1,
        "item_id" => item.id,
        "mode" => "emphasized"
      })

    assert mismatch["error"]["message"] == "cv_mismatch"

    ok = tool_call(handle, "tailor_line", %{"item_id" => item.id, "mode" => "emphasized"})
    assert ok["result"]["job_id"] == job.id

    moved = tool_call(handle, "set_stage", %{"stage" => "gated"})
    assert moved["result"] == %{"job_id" => job.id, "stage" => "gated"}

    bad = tool_call(handle, "set_stage", %{"stage" => "sent"})
    assert bad["error"]["message"] == "bad argument stage"

    not_int = tool_call(handle, "tailor_line", %{"item_id" => "x"})
    assert not_int["error"]["message"] == "bad argument item_id"
    assert Letterbox.release(handle) == :ok
  end

  test "the directory socket lists letterboxes and refuses writes" do
    %{letterbox_id: letterbox_id} = opened()
    {:ok, state} = McpDirectorySocket.init(%{account_id: Repo.account_id!()})

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

  test "directory list and recommend rank by score_100" do
    profile = profile()
    job(profile, %{company: "Acme Staffing"})
    high = job(profile, %{company: "OpenAI", role: "Research engineer"})

    listed = Mcp.directory(%{"id" => 1, "method" => "tools/list"})
    list_tool = Enum.find(listed.result.tools, &(&1["name"] == "list_applications"))
    rec_tool = Enum.find(listed.result.tools, &(&1["name"] == "recommend_applications"))
    assert list_tool["description"] =~ "score_100"
    assert rec_tool["description"] =~ "score_100"

    apps = tool_call("list_applications", %{"status" => "all"})["result"]["applications"]
    assert hd(apps)["company"] == "OpenAI"
    assert hd(apps)["score_100"] == 100

    rec = tool_call("recommend_applications")
    assert rec["result"]["fire"] == "hold"
    assert Enum.any?(rec["result"]["applications"], &(&1["job_id"] == high.id))
    refute Enum.any?(rec["result"]["applications"], &(&1["score_100"] < 90))

    dist = tool_call("score_distribution", %{"status" => "all"})
    assert dist["result"]["n"] >= 2
    assert Enum.any?(dist["result"]["bands"], &(&1["key"] == "frontier" and &1["count"] >= 1))
  end

  test "the letterbox socket answers a call and pushes only its own notification" do
    %{job: job, letterbox_id: letterbox_id} = opened()
    {:ok, state} = McpSocket.init(%{id: letterbox_id, account_id: Repo.account_id!()})

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

    Phoenix.PubSub.broadcast(Hireme.PubSub, Desk.topic(), {:desk_event, Signal.stage(-1, :gated)})
    refute_receive {:desk_event, _}, 50
    assert McpSocket.terminate(:normal, state) == :ok
  end

  test "a second connection cannot lease the same letterbox" do
    account_id = Repo.account_id!()
    %{letterbox_id: letterbox_id} = opened()
    {:ok, _state} = McpSocket.init(%{id: letterbox_id, account_id: Repo.account_id!()})

    task =
      Task.async(fn ->
        Repo.put_account(account_id)
        McpSocket.init(%{id: letterbox_id, account_id: Repo.account_id!()})
      end)

    assert {:stop, :busy, %{}} = Task.await(task)
  end

  test "directory gym and net tools log conditioning and observer work, not jobs" do
    listed = Mcp.directory(%{"id" => 1, "method" => "tools/list"})
    names = Enum.map(listed.result.tools, & &1["name"])
    assert "gym_status" in names
    assert "gym_log" in names
    assert "net_status" in names
    assert "net_log" in names

    gym_tool = Enum.find(listed.result.tools, &(&1["name"] == "gym_log"))
    assert gym_tool["description"] =~ "FIRE HOLD"
    assert gym_tool["description"] =~ "does not submit"

    logged =
      tool_call("gym_log", %{
        "platform" => "leetcode",
        "title" => "Number of Islands",
        "topic" => "graphs",
        "outcome" => "solved"
      })

    assert logged["result"]["title"] == "Number of Islands"
    assert logged["result"]["progress"]["solved_today"] == 1
    assert logged["result"]["progress"]["note"] =~ "not Life-EV"
    assert tool_call("gym_status")["result"]["streak"] >= 1

    lane = tool_call("net_set_lane", %{"url" => "https://observer.example.test/lane"})
    assert lane["result"]["lane"] == "https://observer.example.test/lane"

    post = tool_call("net_log", %{"kind" => "observer", "title" => "Evening pass"})
    assert post["result"]["kind"] == "observer"
    assert post["result"]["progress"]["observer_runs"] == 1
    assert post["result"]["progress"]["note"] =~ "Not CRM"

    bad = tool_call("gym_log", %{"platform" => "leetcode"})
    assert bad["error"]["message"] == "bad argument title"

    assert is_list(tool_call("list_applications", %{"status" => "all"})["result"]["applications"])
  end

  test "directory heat_status and can_apply gate the queue without submitting" do
    listed = Mcp.directory(%{"id" => 1, "method" => "tools/list"})
    names = Enum.map(listed.result.tools, & &1["name"])
    assert "heat_status" in names
    assert "can_apply" in names

    job = job(profile(), %{company: "Obscure Shop"})

    status = tool_call("heat_status")
    assert status["result"]["note"] =~ "does not submit"
    assert is_list(status["result"]["companies"])

    allowed = tool_call("can_apply", %{"role_id" => job.id})
    assert allowed["result"]["decision"] in ["allow", "defer"]
    assert allowed["result"]["fire"] == "hold"
  end

  defp opened do
    profile = profile()
    job = job(profile, %{company: "Batch Co #{uniq()}"})
    %{job: job, item: item(profile), letterbox_id: Letterbox.for_job(job.id).id}
  end
end
