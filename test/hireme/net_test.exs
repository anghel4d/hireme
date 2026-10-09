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
end
