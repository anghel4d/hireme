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

  def uniq, do: System.unique_integer([:positive])

  @doc """
  Hold `job_id`'s lease in a process of its own, as an agent's lane
  would: `{claim_result, pid}`. `let_go/1` releases it as a closing
  lane does.
  """
  def hold_lease(job_id) do
    account_id = Hireme.Repo.account_id!()
    me = self()

    pid =
      spawn(fn ->
        Hireme.Repo.put_account(account_id)
        claim = Hireme.Letterbox.claim(job_id)
        send(me, {:held, self(), claim})

        receive do
          {:let_go, from} ->
            with {:ok, pair} <- claim, do: Hireme.Letterbox.release(pair)
            send(from, {:gone, self()})
        end
      end)

    receive do
      {:held, ^pid, result} -> {result, pid}
    end
  end

  @doc "End a lease `hold_lease/1` took."
  def let_go(pid) do
    send(pid, {:let_go, self()})

    receive do
      {:gone, ^pid} -> :ok
    end
  end

  @doc """
  A form drawn from `choices`: each field a random one of its choices, under
  a string or an atom key, and some fields left out. Members of a closed set
  travel as atoms or names.
  """
  def form(choices) do
    for {field, values} <- choices, :rand.uniform(4) > 1, into: %{} do
      value =
        case Enum.random(values) do
          atom when is_atom(atom) and not is_nil(atom) ->
            Enum.random([atom, Atom.to_string(atom)])

          other ->
            other
        end

      {Enum.random([Atom.to_string(field), field]), value}
    end
  end
end
