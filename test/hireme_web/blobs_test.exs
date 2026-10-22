defmodule HiremeWeb.BlobsTest do
  use HiremeWeb.ConnCase, async: false
  import Ecto.Query
  import Hireme.WireCase, only: [op: 3, run: 2]
  alias Hireme.{Grants, Keys, Repo, Schema}

  @pdf "application/pdf"
  @docx "application/vnd.openxmlformats-officedocument.wordprocessingml.document"

  # A PDF as Skia writes one for CID fonts: each line in a font of its own,
  # subset from the same glyph ids (so one font's codes are another's
  # letters), a ToUnicode map per font, glyphs placed one by one, deflated.
  defp pdf(lines) do
    n = length(lines)

    gids =
      Enum.map(lines, fn l ->
        l
        |> String.codepoints()
        |> Enum.uniq()
        |> Enum.with_index(3)
        |> Map.new(fn {g, i} -> {g, hex16(i)} end)
      end)

    cmap = fn gid ->
      pairs =
        Enum.map_join(gid, "\n", fn {g, c} ->
          "<#{c}> <#{Base.encode16(:unicode.characters_to_binary(g, :utf8, {:utf16, :big}))}>"
        end)

      "begincmap\n#{map_size(gid)} beginbfchar\n#{pairs}\nendbfchar\nendcmap"
    end

    content =
      lines
      |> Enum.zip(gids)
      |> Enum.with_index()
      |> Enum.map_join("\n", fn {{l, gid}, i} ->
        shown = l |> String.codepoints() |> Enum.map_join(" 7.5 0 Td ", &"<#{gid[&1]}> Tj")
        "BT /F#{i} 12 Tf 1 0 0 -1 40 #{60 + 16 * i} Tm #{shown} ET"
      end)

    names = Enum.map_join(0..(n - 1), " ", &"/F#{&1} #{5 + &1} 0 R")

    objects =
      [
        "<< /Type /Catalog /Pages 2 0 R >>",
        "<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
        "<< /Type /Page /Parent 2 0 R /Contents 4 0 R /Resources << /Font << #{names} >> >> >>",
        stream(content)
      ] ++
        Enum.map(
          0..(n - 1),
          &"<< /Type /Font /Subtype /Type0 /Encoding /Identity-H /ToUnicode #{5 + n + &1} 0 R >>"
        ) ++
        Enum.map(gids, &stream(cmap.(&1)))

    body =
      objects
      |> Enum.with_index(1)
      |> Enum.map_join("\n", fn {o, n} -> "#{n} 0 obj\n#{o}\nendobj" end)

    "%PDF-1.7\n#{body}\ntrailer << /Root 1 0 R >>\n%%EOF\n"
  end

  defp stream(text) do
    z = :zlib.compress(text)
    "<< /Length #{byte_size(z)} /Filter /FlateDecode >>\nstream\n" <> z <> "\nendstream"
  end

  defp hex16(n), do: n |> Integer.to_string(16) |> String.pad_leading(4, "0")

  defp docx(paragraphs) do
    ps = Enum.map_join(paragraphs, &"<w:p><w:r><w:t>#{&1}</w:t></w:r></w:p>")
    xml = ~s(<?xml version="1.0"?><w:document xmlns:w="w"><w:body>#{ps}</w:body></w:document>)
    files = [{~c"[Content_Types].xml", "<Types/>"}, {~c"word/document.xml", xml}]
    {:ok, {_, zip}} = :zip.create(~c"cv.docx", files, [:memory])
    zip
  end

  defp request(method, path, auth, body \\ "", type \\ nil) do
    conn = Plug.Test.conn(method, "https://www.example.com" <> path, body)
    conn = if type, do: put_req_header(conn, "content-type", type), else: conn

    case auth do
      {:key, secret} ->
        put_req_header(conn, "authorization", "Bearer " <> secret)

      {:session, token} ->
        conn |> put_private(:plug_skip_csrf_protection, true) |> signed_in(token)
    end
    |> HiremeWeb.Endpoint.call([])
  end

  defp sha(bytes), do: :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
  defp body(conn), do: JSON.decode!(conn.resp_body)

  test "a key with the corpus bit keeps a file once and reads it back named; without the bit, or another account's, it is refused" do
    %{session: s} = sign_in()
    {:ok, %{secret: rw}} = Keys.mint(s, "rw", Keys.preset(:read_write))
    corpus = Grants.bit(Schema.table(:blobs))
    others = Grants.all() - corpus

    {:ok, %{secret: blind}} =
      Keys.mint(s, "blind", %{read_mask: others, write_mask: others, may_delete: false})

    %{session: s2} = sign_in()
    {:ok, %{secret: stranger}} = Keys.mint(s2, "other", Keys.preset(:read_write))

    file = pdf(["Ana Pereira"])
    put = request(:put, "/blobs", {:key, rw}, file, @pdf)
    assert put.status == 201
    assert body(put) == %{"sha" => sha(file), "bytes" => byte_size(file), "type" => @pdf}
    assert request(:put, "/blobs", {:key, rw}, file, @pdf).status == 200

    got = request(:get, "/blobs/#{sha(file)}?name=Ana%20CV.pdf", {:key, rw})
    assert got.status == 200 and got.resp_body == file
    assert get_resp_header(got, "content-type") == [@pdf]
    assert [disposition] = get_resp_header(got, "content-disposition")
    assert disposition =~ ~r/^inline; / and disposition =~ "filename*=UTF-8''Ana%20CV.pdf"

    assert request(:put, "/blobs", {:key, blind}, file, @pdf).status == 403
    assert request(:get, "/blobs/#{sha(file)}", {:key, blind}).status == 403
    assert request(:get, "/blobs/#{sha(file)}", {:key, stranger}).status == 404
    assert request(:put, "/blobs", {:key, rw}, "<p>hi</p>", "text/html").status == 415
  end

  test "a browser keeps a file under its session and CSRF token; a version of it carries the file's text, and a markdown version its body" do
    %{account: a, token: token} = sign_in()

    unsigned = Plug.Test.conn(:put, "https://www.example.com/blobs", "x") |> signed_in(token)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      HiremeWeb.Endpoint.call(unsigned, [])
    end

    file = pdf(["Ana Pereira", "Rust engineer — Zürich"])
    assert request(:put, "/blobs", {:session, token}, file, @pdf).status == 201
    word = docx(["Kernels &amp; GPUs", "Lisbon"])
    assert request(:put, "/blobs", {:session, token}, word, @docx).status == 201
    broken = "%PDF-1.4\nnot a page in sight"
    assert request(:put, "/blobs", {:session, token}, broken, @pdf).status == 201

    {[pdf_root, docx_root, md_root], []} =
      run(a.id, [
        op(:put, :cv_roots, %{slug: "pdf", name: "PDF", format: :pdf}),
        op(:put, :cv_roots, %{slug: "docx", name: "Word", format: :docx}),
        op(:put, :cv_roots, %{slug: "md", name: "Markdown", format: :markdown})
      ])

    version = &op(:put, :cv_versions, Map.put(&2, :root_id, &1.id))

    {[_, _, _, _, _], []} =
      run(a.id, [
        version.(pdf_root, %{blob_sha: sha(file), blob_name: "ana.pdf"}),
        version.(docx_root, %{blob_sha: sha(word), blob_name: "ana.docx"}),
        version.(pdf_root, %{blob_sha: sha(broken)}),
        version.(md_root, %{body: "# Ana\n\nRust"}),
        version.(md_root, %{body: "# Ana Pereira"})
      ])

    rows =
      Repo.with_account(a.id, fn ->
        Repo.all(from(v in Hireme.Rows.CvVersion, order_by: v.id))
      end)

    assert [p1, d1, p2, m1, m2] = rows

    assert {p1.n, p1.text, p1.blob_type, p1.blob_bytes, p1.actor} ==
             {1, "Ana Pereira\nRust engineer — Zürich", @pdf, byte_size(file), :operator}

    assert {d1.n, d1.text, d1.blob_type} == {1, "Kernels & GPUs\nLisbon", @docx}
    assert {p2.n, p2.text} == {2, nil}
    assert {m1.n, m1.text, m2.n, m2.text} == {1, "# Ana\n\nRust", 2, "# Ana Pereira"}

    {[], [nack]} = run(a.id, version.(pdf_root, %{blob_sha: String.duplicate("0", 64)}))
    assert nack.refusal == :blob_missing
  end
end
