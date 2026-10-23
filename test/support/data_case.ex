defmodule Hireme.DataCase do
  @moduledoc """
  A test that touches the database: a sandboxed connection, no account on
  the process, and empty rate limiters (they live in ETS and outlive the
  sandbox, while account ids repeat across tests).
  """

  use ExUnit.CaseTemplate
  import Ecto.Query
  alias Ecto.Adapters.SQL
  alias Ecto.Adapters.SQL.Sandbox

  using do
    quote do
      import Ecto.Query
      import Hireme.DataCase
      alias Hireme.Repo
    end
  end

  setup tags do
    setup_sandbox(tags)
    :ok
  end

  @doc """
  The sandbox, holding the write lock; every account's sequencer stopped
  when the test ends (a page load or a write boots one, and the next test's
  account takes the same id), each before its sandbox goes.
  """
  def setup_sandbox(tags) do
    pid = Sandbox.start_owner!(Hireme.Repo, shared: not tags[:async])
    ExUnit.Callbacks.on_exit(fn -> Sandbox.stop_owner(pid) end)

    ExUnit.Callbacks.on_exit(fn ->
      for {_, seq, _, _} <- DynamicSupervisor.which_children(Hireme.Sequencer.Dynamic),
          do: DynamicSupervisor.terminate_child(Hireme.Sequencer.Dynamic, seq)
    end)

    # The sandbox's transaction is deferred, and a deferred transaction that
    # has read cannot wait for the write lock: SQLite answers BUSY at once,
    # past the busy timeout, while the last test's connection may still be
    # rolling back. A write before any read takes the lock where the timeout
    # waits, so every test starts holding it.
    SQL.query!(Hireme.Repo, "UPDATE schema_files SET applied_at = applied_at WHERE 0")
    Hireme.Repo.put_account(nil)
    :ets.delete_all_objects(Hireme.RateLimit)
    # Like the limiter, the coalescer's counts outlive a test's sandbox.
    :ets.delete_all_objects(Hireme.Audit.Coalescer)
    fresh_window(tags[:window])
  end

  # A test that counts calls against a fixed-window limit (`@tag window:
  # :name`, or a list) must not straddle a window's end, or the count resets
  # under it: with less than 15 s of a window left, wait for the next.
  defp fresh_window(nil), do: :ok
  defp fresh_window(names) when is_list(names), do: Enum.each(names, &fresh_window/1)

  defp fresh_window(name) do
    {scale, _} = Hireme.Security.limits()[name]
    left = scale - rem(System.system_time(:millisecond), scale)
    if left < 15_000, do: Process.sleep(left + 50)
    :ok
  end

  @doc "The latest trail rows on the process's account, newest first."
  def recent(limit \\ 50),
    do: Hireme.Repo.all(from(e in Hireme.Rows.Audit, order_by: [desc: e.id], limit: ^limit))

  @doc "The account's identities on the process, oldest first."
  def identities, do: Hireme.Repo.all(from(i in Hireme.Rows.Identity, order_by: i.id))

  @doc """
  A signed-in account through the same path a mailed link takes. Answers
  the account, its session, and the cookie token.
  """
  def sign_in(email \\ "person#{System.unique_integer([:positive])}@example.com") do
    {:ok, token, session} =
      Hireme.Accounts.sign_in_with(:email, %{subject: email, display: email}, %{ip: "127.0.0.1"})

    %{
      account: Hireme.Accounts.get(session.account_id),
      session: session,
      token: token,
      email: email
    }
  end

  @doc "Move a row's timestamps into the past, as a clock would."
  def age(row, field, seconds) do
    row
    |> Ecto.Changeset.change([{field, DateTime.add(Map.fetch!(row, field), -seconds)}])
    |> Hireme.Repo.update!(skip_account: true)
  end
end
