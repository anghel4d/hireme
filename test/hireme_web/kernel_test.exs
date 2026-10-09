defmodule HiremeWeb.KernelTest do
  @moduledoc """
  The committed kernel.wasm speaks the current wire schema.

  The kernel compiles the schema hash in, so a schema change without a
  rebuild would make every browser refuse every frame. This reads the
  `schema_hash` export straight out of the module's code section and
  compares it with the hash the encoder stamps. (`native/kernel/build.sh
  --check` proves the bytes themselves reproduce from source.)
  """

  use ExUnit.Case, async: true

  import Bitwise

  @wasm Path.expand("../../priv/static/wasm/kernel.wasm", __DIR__)

  test "kernel.wasm was built against the schema the encoder uses" do
    assert {:ok, hash} = exported_constant(File.read!(@wasm), "schema_hash")
    assert hash == HiremeWeb.Packet.schema_hash()
  end

  # The i32 constant a nullary export returns: its body is `i32.const n; end`.
  defp exported_constant(<<0, "asm", 1::little-32, rest::binary>>, name) do
    sections = sections(rest, %{})
    imported = sections |> Map.get(2, <<>>) |> imported_funcs()
    {:ok, index} = sections |> Map.fetch!(7) |> export_index(name)
    bodies = sections |> Map.fetch!(10) |> vec(&body/1)

    case Enum.at(bodies, index - imported) do
      <<0, 0x41, rest::binary>> ->
        {n, <<0x0B>>} = sleb(rest)
        {:ok, n}

      other ->
        {:error, other}
    end
  end

  defp sections(<<>>, acc), do: acc

  defp sections(<<id, rest::binary>>, acc) do
    {size, rest} = uleb(rest)
    <<content::binary-size(^size), rest::binary>> = rest
    sections(rest, Map.put(acc, id, content))
  end

  defp imported_funcs(<<>>), do: 0

  defp imported_funcs(bin) do
    bin
    |> vec(fn b ->
      {_mod, b} = name(b)
      {_field, <<kind, b::binary>>} = name(b)

      if kind != 0, do: raise("kernel.wasm should import functions only, if anything")
      {_type, b} = uleb(b)
      {:func, b}
    end)
    |> length()
  end

  defp export_index(bin, want) do
    bin
    |> vec(fn b ->
      {name, <<_kind, b::binary>>} = name(b)
      {index, b} = uleb(b)
      {{name, index}, b}
    end)
    |> List.keyfind(want, 0)
    |> case do
      {_, index} -> {:ok, index}
      nil -> :error
    end
  end

  defp body(b) do
    {size, b} = uleb(b)
    <<code::binary-size(^size), rest::binary>> = b
    {code, rest}
  end

  defp vec(bin, item) do
    {n, rest} = uleb(bin)

    {items, _rest} =
      Enum.map_reduce(List.duplicate(nil, n), rest, fn _, b -> item.(b) end)

    items
  end

  defp name(b) do
    {len, b} = uleb(b)
    <<s::binary-size(^len), rest::binary>> = b
    {s, rest}
  end

  defp uleb(b, shift \\ 0, acc \\ 0)
  defp uleb(<<1::1, v::7, rest::binary>>, s, acc), do: uleb(rest, s + 7, acc + (v <<< s))
  defp uleb(<<0::1, v::7, rest::binary>>, s, acc), do: {acc + (v <<< s), rest}

  defp sleb(b, shift \\ 0, acc \\ 0)
  defp sleb(<<1::1, v::7, rest::binary>>, s, acc), do: sleb(rest, s + 7, acc + (v <<< s))

  defp sleb(<<0::1, v::7, rest::binary>>, s, acc) do
    n = acc + (v <<< s)
    if (v &&& 0x40) != 0, do: {n - (1 <<< (s + 7)), rest}, else: {n, rest}
  end
end
