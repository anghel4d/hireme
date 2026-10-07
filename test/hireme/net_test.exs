defmodule Hireme.NetTest do
  use Hireme.DataCase, async: false

  alias Hireme.Net

  @today ~D[2026-10-07]

  test "closed kinds and channels parse at the edge" do
    assert Net.parse_kind("observer") == {:ok, :observer}
    assert Net.parse_kind("draft") == {:ok, :draft}
    assert Net.parse_channel("x") == {:ok, :x}
    assert Net.parse_channel("broadside") == {:ok, :broadside}
    assert Net.parse_kind("contact") == :error
    assert Net.parse_channel("linkedin-spam") == :error
  end

  test "observer runs, shipped posts, and drafts are counted without being a CRM" do
    assert {:ok, _} = Net.set_lane("https://observer.example.test/lane")

    assert {:ok, _} =
             Net.log(
               %{"kind" => "observer", "title" => "Morning Broadside pass"},
               @today
             )

    assert {:ok, _} =
             Net.log(
               %{
                 "kind" => "post",
                 "channel" => "x",
                 "title" => "Shipped the gym lane",
                 "url" => "https://x.com/example/status/1"
               },
               @today
             )

    assert {:ok, _} =
             Net.log(
               %{"kind" => "draft", "title" => "Outreach to a lab, unsent", "body" => "hello"},
               @today
             )

    progress = Net.progress(@today)
    assert progress.lane == "https://observer.example.test/lane"
    assert progress.observer_runs == 1
    assert progress.shipped_week == 1
    assert progress.drafts == 1
    refute Enum.any?(progress.recent, &Map.has_key?(&1, :email))
  end

  test "a draft does not count as shipped" do
    {:ok, draft} = Net.log(%{"kind" => "draft", "title" => "Still a draft"}, @today)
    assert draft.shipped_on == nil
    assert Net.progress(@today).shipped_week == 0
  end

  test "mixed-key forms keep wire precedence for kind, text, and dates" do
    assert {:ok, entry} =
             Net.log(
               %{
                 :kind => :draft,
                 "kind" => "post",
                 :title => nil,
                 "title" => "Wire title",
                 :shipped_on => nil,
                 "shipped_on" => "2020-01-01",
                 :body => "atom body",
                 "body" => nil,
                 :url => "atom URL",
                 "url" => ""
               },
               @today
             )

    assert {entry.kind, entry.channel, entry.shipped_on} == {:post, :x, ~D[2020-01-01]}
    assert {entry.title, entry.body, entry.url} == {"Wire title", "atom body", ""}

    assert Net.log(
             %{"kind" => "post", "title" => "Bad date", "shipped_on" => " 2020-01-01 "},
             @today
           ) ==
             {:error, {:argument, "shipped_on"}}
  end

  test "ascii says not CRM" do
    text = Net.ascii(Net.progress(@today))
    assert text =~ "NET"
    assert text =~ "Not CRM"
  end
end
