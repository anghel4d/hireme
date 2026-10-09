defmodule Hireme.NetTest do
  use Hireme.DataCase, async: false

  alias Hireme.Net

  @today ~D[2026-10-07]

  test "any form logs an entry whose closed fields are members, or names the field it refuses" do
    :rand.seed(:exsss, {2026, 10, 9})
    members = %{kind: Net.kinds(), channel: Net.channels()}

    results =
      for i <- 1..150 do
        form =
          Hireme.Fixtures.form(
            Map.merge(members, %{
              title: ["Post #{i}", "", " "],
              url: ["https://x.test/#{i}", ""],
              body: ["", "b"],
              shipped_on: ["2026-10-09", "2026-13-40", "", nil]
            })
          )

        case Net.log(form, @today) do
          {:ok, %Net.Entry{} = e} ->
            assert e.kind in members.kind and e.channel in members.channel and e.title != ""
            assert is_nil(e.shipped_on) or match?(%Date{}, e.shipped_on)
            :ok

          {:error, {:argument, field}} when is_binary(field) ->
            :refused
        end
      end

    assert :ok in results and :refused in results
  end
end
