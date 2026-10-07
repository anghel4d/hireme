defmodule Hireme.Fixtures do
  @moduledoc """
  The rows every test opens with: a profile, a line on it, and an
  application. Defaults are unique wherever the schema demands it;
  pass `attrs` for anything a test asserts on.
  """

  alias Hireme.Corpus
  alias Hireme.Desk

  def profile(attrs \\ %{}) do
    Corpus.create_profile!(
      Map.merge(
        %{
          slug: "candidate-#{uniq()}",
          name: "Sample Candidate",
          headline: "Engineer",
          summary: "A sample profile."
        },
        attrs
      )
    )
  end

  def item(profile, attrs \\ %{}) do
    Corpus.create_item!(
      Map.merge(
        %{
          profile_id: profile.id,
          kind: :experience,
          key: "exp.#{uniq()}",
          title: "Line",
          body: "Root line",
          position: 1
        },
        attrs
      )
    )
  end

  def job(profile, attrs \\ %{}) do
    Desk.create_job!(
      Map.merge(
        %{
          profile_id: profile.id,
          company: "Sample Co",
          role: "Engineer",
          stage: "discovered",
          canonical_url: "https://jobs.example.test/#{uniq()}"
        },
        attrs
      )
    )
  end

  @doc "One `tools/call` frame on the directory socket, or on a leased handle, read as the JSON the socket sends."
  def tool_call(name, args \\ %{}) do
    wire(HiremeWeb.Mcp.directory(frame(name, args)))
  end

  def tool_call(handle, name, args) do
    wire(HiremeWeb.Mcp.handle(handle, frame(name, args)))
  end

  defp wire(reply), do: reply |> Jason.encode!() |> Jason.decode!()

  defp frame(name, args) do
    %{
      "id" => uniq(),
      "method" => "tools/call",
      "params" => %{"name" => name, "arguments" => args}
    }
  end

  def uniq, do: System.unique_integer([:positive])
end
