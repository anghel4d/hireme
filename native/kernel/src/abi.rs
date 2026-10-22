//! The kernel as the outside calls it: [`Kernel`], the one facade the
//! NIF and `hireme-mcp` drive natively, and the WebAssembly exports the
//! browser drives, which are the same methods behind a C ABI.
//!
//! A `Kernel` holds an account's resident rows, the board derived from
//! them, and the day it judges by (the `clock` table's, else what the
//! caller set). Every write that reaches the rows (a frame, a prediction,
//! a settle or rollback) also tells the board what moved.
//!
//! **Wasm calling convention.** Memory is the module's own: `alloc(len)`
//! returns a buffer the caller fills, and the caller frees it with
//! `dealloc(ptr, len)` after the call that read it. A call that returns
//! bytes (a document, an id list, a refusal) leaves them in one result
//! buffer and returns its length (or `-1` for none / an error); read it
//! at `result_ptr()` before the next call. Column views (`ids_ptr`,
//! `col_ptr`) point straight into the table's storage and are valid until
//! the next call that writes rows. Strings are `(str_ptr, str_len)` per
//! cell. JSON documents are UTF-8.

use alloc::collections::BTreeMap;
use alloc::string::String;
use alloc::vec::Vec;

use schema::{col, refusal, table};
use serde_json::{json, Value as Json};

use crate::board::{Board, Dir, Filter};
use crate::judge::{self, Ctx, EVal, Refusal};
use crate::pipeline::Stage;
use crate::rows::{Moved, Rows, Val, Write};
use crate::{compose, pick, query, Day};

#[derive(Debug, PartialEq, Eq)]
pub enum Error {
    /// The frame failed to parse, or names another schema.
    Frame,
    /// A table body failed to apply.
    Body,
    /// A snapshot from another schema or of another shape.
    Snapshot,
}

#[derive(Default)]
pub struct Kernel {
    rows: Rows,
    board: Board,
    /// The caller's day, used until the server's `clock` row arrives.
    today: Day,
    /// The server's own day (the sequencer pins its kernel), which wins
    /// over any `clock` row.
    pinned: Option<Day>,
    stale: bool,
    /// The session's grants, from its WELCOME: what `query` may read.
    grants: query::Grants,
    /// The order indexes `query`'s finds walk, mended as rows move.
    indexes: core::cell::RefCell<query::Indexes>,
    /// Each application's CV part (`compose::cv_part`) by what it read of
    /// the row; dropped whenever items, overlays or lineages move.
    cvs: BTreeMap<u32, (compose::CvKey, (Json, Json))>,
    /// Every application's CV pick under the compiled rules; dropped when
    /// an application, a place, a company, the rules, masks, roots or the
    /// operator's own rows move.
    picks: core::cell::RefCell<Option<pick::Picks>>,
    /// The desk's `columns`, per field, dropped with the picks and when offices move.
    columns: core::cell::RefCell<BTreeMap<usize, Vec<Json>>>,
    /// The typed columns `arrange` sorts and groups on, kept as `columns` is.
    cols: core::cell::RefCell<BTreeMap<String, crate::arrange::Column>>,
}

impl Kernel {
    pub fn new() -> Kernel {
        Kernel { rows: Rows::new(), stale: true, ..Kernel::default() }
    }

    pub fn rows(&self) -> &Rows {
        &self.rows
    }

    /// The session's masks, from its WELCOME, before its BOOT is ingested.
    pub fn set_grants(&mut self, grants: query::Grants) {
        self.grants = grants;
    }

    /// A read of the replica: find, get, text or history (`query`).
    pub fn query(&mut self, req: &Json) -> Result<Json, Refusal> {
        let g = self.grants;
        self.query_as(&g, req)
    }

    /// The same read under another session's grants: the node's kernel answers each MCP session as its key may see.
    pub fn query_as(&mut self, grants: &query::Grants, req: &Json) -> Result<Json, Refusal> {
        match req.get("op").and_then(Json::as_str) {
            Some(op @ ("cv_pick" | "cv_picks" | "cv_explain" | "mask_check" | "mask_fields")) => self.cv_query(grants, op, req),
            Some("columns") => self.columns(grants, req),
            Some("unlinked") => {
                query::readable(grants, Some(&json!("applications")))?;
                Ok(crate::link::unlinked(&self.rows))
            }
            // Applications without an order column are found as the page finds them: the desk's query.
            Some("find") if req["table"] == "applications" && req["order"].is_null() => self.desk(grants, req),
            _ => query::query(&self.rows, grants, &mut self.indexes.borrow_mut(), req, self.today()),
        }
    }

    /// The CV reads: picks, a rule's check and explanation, the field
    /// catalog. They read the rules and, but for the catalog, the applications.
    fn cv_query(&self, g: &query::Grants, op: &str, req: &Json) -> Result<Json, Refusal> {
        query::readable(g, Some(&json!("cv_rules")))?;
        if op == "mask_fields" {
            return Ok(json!({"fields": serde_json::from_str::<Json>(crate::mask::catalog()).unwrap_or_default()}));
        }
        query::readable(g, Some(&json!("applications")))?;
        let mut cache = self.picks.borrow_mut();
        let p = cache.get_or_insert_with(|| pick::Picks::of(&self.rows));
        let app = || {
            req.get("application").and_then(Json::as_u64).and_then(|v| u32::try_from(v).ok()).ok_or_else(|| judge::no(refusal::TYPE, json!({"param": "application"})))
        };
        match op {
            "mask_check" => {
                let text = req.get("text").and_then(Json::as_str).ok_or_else(|| judge::no(refusal::TYPE, json!({"param": "text"})))?;
                let at = req.get("position").and_then(Json::as_u64).map(|v| v as usize);
                Ok(pick::check(&self.rows, &p.arms, text, at))
            }
            "cv_explain" => Ok(pick::explain(&self.rows, &p.arms, app()?)),
            "cv_pick" => {
                let id = app()?;
                p.by.get(&id).map(|k| k.to_json(id)).ok_or_else(|| judge::no(refusal::NOT_FOUND, json!({"table": "applications", "id": id})))
            }
            _ => {
                let state = req.pointer("/where/state").and_then(Json::as_str);
                let picks: Vec<Json> = p.by.iter().filter(|(_, k)| state.is_none_or(|s| k.state.name() == s)).map(|(id, k)| k.to_json(*id)).collect();
                Ok(json!({"picks": picks}))
            }
        }
    }

    /// Any fields of every application, columnar (`pick::columns`), each
    /// field kept until a table it may read moves: the desk's sort and group keys.
    fn columns(&self, g: &query::Grants, req: &Json) -> Result<Json, Refusal> {
        query::readable(g, Some(&json!("applications")))?;
        let asked: Vec<&str> = req.get("fields").and_then(Json::as_array).map(|a| a.iter().filter_map(Json::as_str).collect()).unwrap_or_default();
        let mut fields = Vec::new();
        for p in &asked {
            let f = crate::mask::field(p).ok_or_else(|| judge::no(refusal::TYPE, json!({"param": "fields", "unknown": p})))?;
            fields.push(f);
        }
        let mut cache = self.columns.borrow_mut();
        let missing: Vec<usize> = fields.iter().copied().filter(|f| !cache.contains_key(f)).collect();
        if !missing.is_empty() {
            let (_, cols) = pick::columns(&self.rows, &missing);
            for (f, c) in missing.into_iter().zip(cols) {
                cache.insert(f, c);
            }
        }
        let ids: Vec<u32> = self.rows.table(table::APPLICATIONS).map_or_else(Vec::new, |t| t.ids().to_vec());
        let cols: serde_json::Map<String, Json> = fields.iter().zip(&asked).map(|(f, p)| ((*p).to_string(), Json::Array(cache[f].clone()))).collect();
        Ok(json!({"ids": ids, "cols": cols}))
    }

    /// The board's filtered order, narrowed by work mode and to the
    /// unlinked, sorted on one key and grouped on another (`arrange`): the
    /// desk's select-by-sort over typed columns. Keys are the desk's own
    /// (`arrange::desk`) or catalog fields. Also answers the chips' counts:
    /// work modes over the filtered board, unlinked over the whole desk.
    pub fn arrange(&mut self, req: &Json) -> Result<(Vec<u32>, Json), Refusal> {
        self.derive();
        self.arranged(req, &|_| true)
    }

    /// `arrange` over the derived board, keeping only the ids `also` takes (`desk`'s where).
    fn arranged(&self, req: &Json, also: &dyn Fn(u32) -> bool) -> Result<(Vec<u32>, Json), Refusal> {
        let ids = self.board.view(&filter(&req["filter"].to_string()));
        let rows = &self.rows;
        let Some(t) = rows.table(table::APPLICATIONS) else { return Ok((Vec::new(), json!({"groups": [], "modes": {}, "unlinked": 0}))) };
        use schema::col::applications as A;
        let modes = schema::enums::work_mode::NAMES;
        // The columns read straight, by slot: no lookup per row.
        let column = |c: u16| match t.column(c).map(|c| &c.data) {
            Some(crate::rows::Data::U32(v)) => Some(v.as_slice()),
            _ => None,
        };
        let some = |v: u32| (v != wire::NONE).then_some(v);
        let (wm, corp, place) = (column(A::WORK_MODE), column(A::CORPORATION_ID), column(A::PLACE_ID));
        let at = |v: Option<&[u32]>, slot: usize| v.and_then(|v| some(v[slot]));
        let mode = |slot: usize| at(wm, slot).map_or(modes.len(), |m| (m as usize).min(modes.len()));
        let short = |slot: usize| crate::link::short(at(corp, slot), at(place, slot), at(wm, slot));
        let slots: Vec<(u32, usize)> = ids.iter().filter_map(|&id| t.slot(id).map(|s| (id, s))).collect();
        let mut counts = alloc::vec![0u32; modes.len() + 1];
        for &(_, slot) in &slots {
            counts[mode(slot)] += 1;
        }
        let picked: Vec<usize> = req["modes"].as_array().map(|a| a.iter().filter_map(Json::as_str).map(|m| modes.iter().position(|n| *n == m).unwrap_or(modes.len())).collect()).unwrap_or_default();
        let only = req["unlinked"] == true;
        let ids: Vec<u32> = slots.iter().filter(|&&(id, slot)| (picked.is_empty() || picked.contains(&mode(slot))) && (!only || short(slot)) && also(id)).map(|x| x.0).collect();
        let unlinked = (0..t.len()).filter(|&slot| short(slot)).count();
        let key = |v: &Json| -> Result<Option<String>, Refusal> {
            match v.as_str() {
                None | Some("") => Ok(None),
                Some("mode") => Ok(Some("work_mode".into())),
                Some(k) if crate::arrange::DESK.contains(&k) || crate::mask::field(k).is_some() => Ok(Some(k.into())),
                Some(k) => Err(judge::no(refusal::TYPE, json!({"param": "key", "unknown": k, "known": keys()}))),
            }
        };
        let sort = key(&req["sort"][0])?;
        let group = key(&req["group"])?;
        let mut cols = self.cols.borrow_mut();
        for k in sort.iter().chain(group.iter()) {
            if !cols.contains_key(k) {
                let c = crate::arrange::desk(rows, &self.board, k).unwrap_or_else(|| crate::arrange::field(rows, crate::mask::field(k).unwrap_or(0)));
                cols.insert(k.clone(), c);
            }
        }
        let dir = match req["sort"][1].as_str() {
            Some("desc") => -1,
            Some("asc") => 1,
            _ => sort.as_ref().map_or(1, |k| if cols[k].desc { -1 } else { 1 }),
        };
        let ask = crate::arrange::Ask { sort: sort.as_deref().map(|k| (k, dir)), group: group.as_deref(), largest: req["largest"] == true, cols: &cols };
        // A duplicate set keeps its furthest along, then its lowest number.
        let keep = |id: u32| (t.u32(id, A::STAGE).unwrap_or(0), -i64::from(t.u32(id, A::NO).unwrap_or(u32::MAX)));
        let (order, groups) = crate::arrange::arrange(rows, &ids, &ask, &keep);
        let mut by_mode = serde_json::Map::new();
        for (i, n) in counts.iter().enumerate() {
            by_mode.insert(modes.get(i).copied().unwrap_or("none").into(), json!(n));
        }
        Ok((order, json!({"groups": crate::arrange::groups_json(&groups), "modes": by_mode, "unlinked": unlinked})))
    }

    /// `find` on applications as the page runs it, one `arrange` for both:
    /// the board's filter (`search`, `min_score`, `bands`, `stages`,
    /// `classes`), `modes`, `unlinked`, and `where` over the columns
    /// narrow; `sort` (a desk key or catalog field, `[key, dir]` or the
    /// key) orders, `group` (another key; company unless told otherwise,
    /// "" for none) buckets, `largest` puts the biggest group first.
    /// `after` is the row offset. Each row is find's with its card's
    /// stage, score (the ranking score, stored or suggested), band and class; `groups` are the page's, with absolute
    /// starts; `modes` and `unlinked` are the chips' counts; `listing` is
    /// the page as text, under its group headings.
    fn desk(&mut self, g: &query::Grants, req: &Json) -> Result<Json, Refusal> {
        let tm = query::readable(g, req.get("table"))?;
        let cols = query::columns(g, tm, req.get("cols"), false)?;
        let pass = query::sieve(g, tm, req.get("where"))?;
        let limit = query::bound(req.get("limit"), query::FIND_LIMIT, query::FIND_MAX, "limit")? as usize;
        let after = match req.get("after") {
            None | Some(Json::Null) => 0,
            Some(v) => v.as_u64().ok_or_else(|| judge::no(refusal::TYPE, json!({"param": "after", "need": "the row offset the previous page answered as next"})))? as usize,
        };
        let sort = match req.get("sort") {
            Some(Json::String(k)) => json!([k]),
            Some(v) => v.clone(),
            None => Json::Null,
        };
        let ask = json!({
            "filter": {"bands": req["bands"], "stages": req["stages"], "classes": req["classes"], "min_score": req["min_score"], "search": req["search"]},
            "modes": req["modes"], "unlinked": req["unlinked"], "sort": sort, "group": req.get("group").cloned().unwrap_or_else(|| json!("company")), "largest": req["largest"],
        });
        self.derive();
        let today = self.today();
        let Some(t) = self.rows.table(table::APPLICATIONS) else {
            return Ok(json!({"rows": [], "groups": [], "total": 0, "next": null, "modes": {}, "unlinked": 0, "listing": "no applications\n"}));
        };
        let (order, meta) = self.arranged(&ask, &|id| pass(t, id))?;
        let end = (after + limit).min(order.len());
        let page = &order[after.min(end)..end];
        let grouped = ask["group"].as_str().is_some_and(|g| !g.is_empty());
        let groups: Vec<Json> = meta["groups"]
            .as_array()
            .into_iter()
            .flatten()
            .filter(|g| {
                let (s, n) = (g["start"].as_u64().unwrap_or(0) as usize, g["count"].as_u64().unwrap_or(0) as usize);
                grouped && s < end && s + n > after
            })
            .cloned()
            .collect();
        let rows: Vec<Json> = page
            .iter()
            .map(|&id| {
                let mut r = query::stamped(t, id, &cols, false, today);
                if let Some(c) = self.board.card(id) {
                    r["stage"] = json!(c.stage.name());
                    r["score"] = json!(c.score);
                    r["band"] = json!(c.band.name());
                    r["class"] = json!(c.class.name());
                }
                r
            })
            .collect();
        let listing = listing(t, page, &rows, &groups, order.len(), after, &ask);
        let next = (end < order.len()).then_some(end);
        Ok(json!({"rows": rows, "groups": groups, "total": order.len(), "next": next, "modes": meta["modes"], "unlinked": meta["unlinked"], "listing": listing}))
    }

    /// Application `id`'s CV pick.
    pub fn pick(&self, id: u32) -> Option<pick::Pick> {
        self.picks.borrow_mut().get_or_insert_with(|| pick::Picks::of(&self.rows)).by.get(&id).cloned()
    }

    pub fn set_today(&mut self, today: Day) {
        if self.today != today {
            self.today = today;
            self.stale = true;
        }
    }

    /// The server's day when this kernel is the server's; else the
    /// server's `clock`, so a client never predicts on a day the server
    /// has not reached; else the caller's.
    pub fn today(&self) -> Day {
        let clock = self.rows.table(table::CLOCK).and_then(|t| t.ids().first().and_then(|&id| t.u32(id, col::clock::TODAY)));
        self.pinned.or(clock.map(|d| d as Day)).unwrap_or(self.today)
    }

    /// The server's day for the sequencer's kernel: it wins over any
    /// `clock` row a BOOT carries.
    pub fn pin_today(&mut self, today: Day) {
        if self.pinned != Some(today) {
            self.pinned = Some(today);
            self.stale = true;
        }
    }

    fn moved(&mut self, m: &Moved, day_before: Day) {
        self.indexes.get_mut().moved(m, &self.rows);
        // A TICK that leaves the day as it was moves nothing derived.
        let only_clock = m.tables.keys().chain(&m.replaced).all(|t| *t == table::CLOCK);
        if m.is_empty() || (only_clock && self.today() == day_before) {
            return;
        }
        if [table::ITEMS, table::CV_OVERLAYS, table::CV_LINEAGES, table::CV_ROOTS, table::ME].iter().any(|&t| m.touched(t)) {
            self.cvs.clear();
        }
        let pick_tables = [table::APPLICATIONS, table::PLACES, table::CORPORATIONS, table::CV_RULES, table::CV_MASKS, table::CV_ROOTS, table::ME, table::LANGUAGES];
        // Applications written in place and nothing else a column reads: the
        // typed columns mend those rows instead of being built again.
        let in_place = m.replaced.is_empty()
            && pick_tables[1..].iter().all(|&t| !m.touched(t))
            && !m.touched(table::OFFICES)
            && m.tables.get(&table::APPLICATIONS).is_some_and(|(_, gone)| gone.is_empty());
        if in_place {
            let written = m.tables[&table::APPLICATIONS].0.clone();
            let rows = &self.rows;
            self.cols.get_mut().retain(|k, c| crate::arrange::mend(rows, k, c, &written));
        }
        if pick_tables.iter().any(|&t| m.touched(t)) || !m.replaced.is_empty() {
            // In place, the picks of the written applications are all that can move.
            let mended = in_place && {
                let rows = &self.rows;
                let written = &m.tables[&table::APPLICATIONS].0;
                self.picks.get_mut().as_mut().is_some_and(|p| p.mend(rows, written))
            };
            if !mended {
                *self.picks.get_mut() = None;
            }
            self.columns.get_mut().clear();
            if !in_place {
                self.cols.get_mut().clear();
            }
        } else if m.touched(table::OFFICES) || m.touched(table::LEASES) {
            self.columns.get_mut().clear();
            self.cols.get_mut().clear();
        }
        self.board.forget(m, &self.rows);
        self.stale = true;
    }

    /// A frame body into the rows. A body that fails part way may have
    /// applied some of its blocks, so everything derived is dropped and
    /// rebuilt from the rows on the next derive.
    fn frame(&mut self, body: &[u8], rev: u64, boot: bool) -> Result<Moved, Error> {
        let day = self.today();
        let r = if boot { self.rows.boot(body, rev) } else { self.rows.patch(body, rev) };
        match r {
            Ok(m) => {
                self.moved(&m, day);
                Ok(m)
            }
            Err(_) => {
                self.board = Board::default();
                self.indexes.get_mut().clear();
                self.cvs.clear();
                self.stale = true;
                Err(Error::Body)
            }
        }
    }

    /// A BOOT body (the server's cache build and resync, a snapshot).
    pub fn boot(&mut self, body: &[u8], rev: u64) -> Result<Moved, Error> {
        self.frame(body, rev, true)
    }

    /// A PATCH body.
    pub fn patch(&mut self, body: &[u8], rev: u64) -> Result<Moved, Error> {
        self.frame(body, rev, false)
    }

    /// One whole frame from the server: BOOT, PATCH, TICK, ACK or NACK
    /// (deflated or not). Other kinds move nothing.
    pub fn ingest(&mut self, frame: &[u8]) -> Result<Moved, Error> {
        let f = wire::Frame::parse(frame, schema::WIRE_HASH).map_err(|_| Error::Frame)?;
        let rev = f.header.rev;
        let body = f.body().map_err(|_| Error::Frame)?;
        match f.kind() {
            wire::BOOT | wire::TICK => self.boot(&body, rev),
            wire::PATCH => self.patch(&body, rev),
            kind @ (wire::ACK | wire::NACK) => {
                let ops: Vec<u64> = if kind == wire::ACK {
                    wire::decode_acks(&body).map_err(|_| Error::Frame)?.into_iter().map(|a| a.op_id).collect()
                } else {
                    wire::decode_nacks(&body).map_err(|_| Error::Frame)?.into_iter().map(|n| n.op_id).collect()
                };
                let mut all = Moved::default();
                for op in ops {
                    merge(&mut all, self.rows.resolve(op));
                }
                self.moved(&all, self.today());
                Ok(all)
            }
            _ => Ok(Moved::default()),
        }
    }

    /// The domain verdict on one op, against the base and pending rows,
    /// on the kernel's day (the one the board is derived on), whatever
    /// day the caller's clock says.
    pub fn judge(&mut self, op: &[u8], ctx: &Ctx) -> judge::Verdict {
        let ctx = Ctx { today: self.today(), ..*ctx };
        judge::judge(&self.rows, &mut self.board, op, &ctx)
    }

    /// Judges one op and, if it passes, applies it as pending: the
    /// client's write in its own frame, settled or rolled back later.
    pub fn predict(&mut self, op: &[u8], ctx: &Ctx) -> Result<Moved, Refusal> {
        let effects = self.judge(op, ctx)?;
        let parsed = wire::Op::one(op).map_err(|_| Refusal { code: schema::refusal::TYPE, data: Json::Null })?;
        let writes = writes(&parsed, &effects, &mut || self.rows.temp_id());
        let m = self.rows.apply_pending(parsed.op_id, writes);
        self.moved(&m, self.today());
        Ok(m)
    }

    /// Recomputes the board if anything moved since the last derive.
    pub fn derive(&mut self) {
        if self.stale {
            let today = self.today();
            self.board.derive(&self.rows, today);
            self.stale = false;
            // The desk's card keys (score, band, heat, why) read the board.
            self.cols.get_mut().retain(|k, _| !crate::arrange::DESK.contains(&k.as_str()) || matches!(k.as_str(), "company" | "place" | "dupes" | "added"));
        }
    }

    pub fn board(&mut self) -> &Board {
        self.derive();
        &self.board
    }

    pub fn view(&mut self, f: &Filter) -> Vec<u32> {
        self.board().view(f)
    }

    /// Application ids in board order, optionally of one stage.
    pub fn board_ids(&mut self, stage: Option<Stage>) -> Vec<u32> {
        self.board().ids(stage)
    }

    pub fn application(&mut self, id: u32) -> Option<Json> {
        self.derive();
        let t = self.rows.table(table::APPLICATIONS)?;
        let picked = self.pick(id);
        let root = picked.as_ref().and_then(|p| p.root);
        let key = compose::cv_key(t, id, root);
        let cv = match self.cvs.get(&id) {
            Some((k, cv)) if *k == key => cv.clone(),
            _ => {
                let cv = compose::cv_part(&self.rows, &self.board, t, id, root);
                if self.cvs.len() >= 64 {
                    self.cvs.clear();
                }
                self.cvs.insert(id, (key, cv.clone()));
                cv
            }
        };
        let mut doc = compose::application(&self.rows, &self.board, id, self.today(), cv)?;
        doc["cv_pick"] = picked.map_or(Json::Null, |p| p.to_json(id));
        Some(doc)
    }

    /// The desk at a glance of this replica: today, the scoreboard and the
    /// board's first `top` applications grouped by company (`desk`).
    pub fn overview(&mut self, top: usize) -> Json {
        self.overview_as(&query::Grants { human: true, read_mask: u8::MAX, write_mask: 0, may_delete: false }, top)
    }

    /// The same under a key's grants, for the node's kernel, which holds the
    /// whole account: a key that reads no desk gets today alone.
    pub fn overview_as(&mut self, g: &query::Grants, top: usize) -> Json {
        self.derive();
        let mut doc = json!({"today": crate::day_iso(self.today())});
        if query::readable(g, Some(&json!("applications"))).is_ok() {
            doc["scoreboard"] = self.board.scoreboard(&self.rows, self.today()).to_json();
            doc["top"] = self.desk(g, &json!({"table": "applications", "limit": top})).unwrap_or(Json::Null);
        }
        doc
    }

    pub fn atlas(&self) -> Json {
        compose::atlas_doc(&self.rows)
    }

    /// The base rows for a cold start: `u64 rev | u32 schema_rev | u16
    /// wire_hash | u16 0 | BOOT body`.
    pub fn snapshot(&self) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&self.rows.rev.to_le_bytes());
        out.extend_from_slice(&schema::SCHEMA_REV.to_le_bytes());
        out.extend_from_slice(&schema::WIRE_HASH.to_le_bytes());
        out.extend_from_slice(&[0, 0]);
        out.extend_from_slice(&self.rows.snapshot());
        out
    }

    /// A snapshot back into an empty kernel; the rev it was taken at.
    pub fn restore(&mut self, snap: &[u8]) -> Result<u64, Error> {
        if snap.len() < 16 {
            return Err(Error::Snapshot);
        }
        let rev = u64::from_le_bytes(snap[0..8].try_into().map_err(|_| Error::Snapshot)?);
        let srev = u32::from_le_bytes(snap[8..12].try_into().map_err(|_| Error::Snapshot)?);
        let hash = u16::from_le_bytes([snap[12], snap[13]]);
        if srev != schema::SCHEMA_REV || hash != schema::WIRE_HASH {
            return Err(Error::Snapshot);
        }
        let (today, pinned, grants) = (self.today, self.pinned, self.grants);
        *self = Kernel::new();
        (self.today, self.pinned, self.grants) = (today, pinned, grants);
        self.boot(&snap[16..], rev).map_err(|_| Error::Snapshot)?;
        Ok(rev)
    }
}

fn merge(into: &mut Moved, m: Moved) {
    for (t, (w, g)) in m.tables {
        let e = into.tables.entry(t).or_default();
        e.0.extend(w);
        e.1.extend(g);
    }
    into.replaced.extend(m.replaced);
}

/// An op's effects as row writes, inserts given ids by `fresh`.
pub fn writes(op: &wire::Op, effects: &[judge::Row], fresh: &mut dyn FnMut() -> u32) -> Vec<Write> {
    let mut out = Vec::new();
    if op.verb == wire::DROP {
        out.push(Write::Remove { table: op.table, id: op.target });
    }
    let mut inserted: Vec<u32> = Vec::new();
    // Ids first, so a ref resolves whatever its row's position.
    let ids: Vec<u32> = effects
        .iter()
        .map(|r| {
            if r.id != 0 {
                return r.id;
            }
            let id = fresh();
            inserted.push(id);
            id
        })
        .collect();
    for (r, &id) in effects.iter().zip(&ids) {
        if r.id == 0 {
            out.push(Write::Insert { table: r.table, id });
        }
        for (c, v) in &r.cells {
            let val = match v {
                EVal::Val(v) => v.clone(),
                EVal::New(k) => inserted.get(*k as usize).map_or(Val::None, |&i| Val::U32(i)),
            };
            out.push(Write::Set { table: r.table, id, col: *c, val });
        }
    }
    out
}

/// A board filter from JSON: `{bands, stages, classes, min_score, search}`,
/// the masks as numbers or lists of names.
pub fn filter(json: &str) -> Filter {
    let v: Json = serde_json::from_str(json).unwrap_or(Json::Null);
    let mask = |key: &str, names: &dyn Fn(&str) -> Option<u8>| -> u32 {
        match &v[key] {
            Json::Number(n) => n.as_u64().unwrap_or(0) as u32,
            Json::Array(a) => a.iter().filter_map(|x| x.as_str()).filter_map(names).fold(0, |m, b| m | 1 << b),
            _ => 0,
        }
    };
    Filter {
        bands: mask("bands", &|s| crate::score::Band::parse(s).map(|b| b as u8)) as u8,
        stages: mask("stages", &|s| Stage::parse(s).map(|b| b as u8)) as u16,
        classes: mask("classes", &|s| crate::heat::Class::parse(s).map(|b| b as u8)) as u8,
        min_score: v["min_score"].as_u64().unwrap_or(0).min(100) as u8,
        search: v["search"].as_str().map(String::from).unwrap_or_default(),
    }
}

/// The keys `arrange` sorts and groups on: the desk's own, then the catalog's fields.
fn keys() -> Vec<&'static str> {
    crate::arrange::DESK.iter().copied().chain(crate::mask::FIELDS.iter().map(|f| f.path)).collect()
}

/// A desk page as an agent reads it: how it stands, a heading per group,
/// a line per application, and the offset of the page after it.
fn listing(t: &crate::rows::Table, page: &[u32], rows: &[Json], groups: &[Json], total: usize, after: usize, ask: &Json) -> String {
    use core::fmt::Write;
    use schema::col::applications as A;
    let mut s = String::new();
    let how = match ask["sort"][0].as_str() {
        Some(k) => alloc::format!("sorted by {k}{}", ask["sort"][1].as_str().map_or(String::new(), |d| alloc::format!(" {d}"))),
        None => "in board order (score, then heat)".into(),
    };
    let by = ask["group"].as_str().filter(|g| !g.is_empty()).map_or(String::new(), |g| alloc::format!(", grouped by {g}"));
    let shown = if page.is_empty() { "none".into() } else { alloc::format!("{}-{}", after + 1, after + page.len()) };
    let _ = writeln!(s, "{total} applications {how}{by}; rows {shown}");
    let mut heading: Option<&Json> = None;
    for (i, (&id, r)) in page.iter().zip(rows).enumerate() {
        let at = (after + i) as u64;
        let g = groups.iter().find(|g| g["start"].as_u64().is_some_and(|st| st <= at && at < st + g["count"].as_u64().unwrap_or(0)));
        if g.is_some() && g.map(|g| &g["key"]) != heading.map(|g| &g["key"]) {
            heading = g;
            let _ = writeln!(s, "\n{} ({})", g.map_or("", |g| g["label"].as_str().unwrap_or("")), g.map_or(0, |g| g["count"].as_u64().unwrap_or(0)));
        }
        let text = |c: u16| t.str(id, c).unwrap_or("");
        let parts: Vec<&str> = [text(A::COMPANY), text(A::ROLE), text(A::LOCATION)].into_iter().filter(|p| !p.is_empty()).collect();
        let mut tail: Vec<String> = parts.iter().map(|p| String::from(*p)).collect();
        tail.extend(r["stage"].as_str().map(String::from));
        if let (Some(class), Some(score)) = (r["class"].as_str(), r["score"].as_u64()) {
            tail.push(alloc::format!("{class} {score}"));
        }
        if r["stale"] == true {
            tail.push("stale".into());
        }
        let _ = writeln!(s, "  #{}  {}", t.u32(id, A::NO).unwrap_or(id), tail.join(" · "));
    }
    if after + page.len() < total {
        let _ = writeln!(s, "\nnext: {{\"after\": {}}}", after + page.len());
    }
    s
}

/// Effects as JSON: `[{table, id, cells: {column: value}}]` with names
/// from the catalog; a value is null, a number, a string or `{"new": k}`
/// (the id of the k-th insert).
pub fn effects_json(rows: &[judge::Row]) -> Json {
    let rows: Vec<Json> = rows
        .iter()
        .map(|r| {
            let def = schema::table_def(r.table);
            let cells: serde_json::Map<String, Json> = r
                .cells
                .iter()
                .map(|(c, v)| {
                    let name = def.and_then(|d| d.col(*c)).map_or_else(|| c.to_string(), |c| c.name.into());
                    let v = match v {
                        EVal::New(k) => json!({"new": k}),
                        EVal::Val(v) => v.json(),
                    };
                    (name, v)
                })
                .collect();
            json!({"table": def.map_or("", |d| d.name), "id": r.id, "cells": cells})
        })
        .collect();
    Json::Array(rows)
}

/// The catalog the kernel was built against: `{wire_hash, schema_rev,
/// tables: {name: {id, residency, cols: {name: {id, wire, type, target}}}},
/// enums: {name: [values]}, commands: {name: {id, table, params: {name: id}}}}`.
pub fn catalog_json() -> Json {
    let tables: serde_json::Map<String, Json> = schema::TABLES
        .iter()
        .map(|t| {
            let cols: serde_json::Map<String, Json> = t
                .cols
                .iter()
                .map(|c| (c.name.into(), json!({"id": c.id, "wire": c.wire, "type": c.type_code, "target": c.target})))
                .collect();
            (t.name.into(), json!({"id": t.id, "residency": alloc::format!("{:?}", t.residency).to_lowercase(), "cols": cols}))
        })
        .collect();
    let enums: serde_json::Map<String, Json> = schema::ENUMS.iter().map(|(n, v)| ((*n).into(), json!(v))).collect();
    let commands: serde_json::Map<String, Json> = schema::COMMANDS
        .iter()
        .map(|c| {
            let params: serde_json::Map<String, Json> =
                c.params.iter().map(|p| (p.name.into(), json!({"id": p.id, "wire": p.wire, "type": p.type_code, "target": p.target}))).collect();
            (c.name.into(), json!({"id": c.id, "table": c.table, "human_only": c.human_only, "params": params}))
        })
        .collect();
    json!({"wire_hash": schema::WIRE_HASH, "schema_rev": schema::SCHEMA_REV, "tables": tables, "enums": enums, "commands": commands})
}

pub fn refusal_json(r: &Refusal) -> Json {
    let name = schema::refusal::NAMES.get(r.code as usize).copied().unwrap_or("internal");
    json!({"code": r.code, "refusal": name, "data": r.data})
}

/// A keyboard direction by its code (0 next, 1 prev, 2 up, 3 down, 4
/// first, else last).
pub fn dir(code: u32) -> Dir {
    [Dir::Next, Dir::Prev, Dir::Up, Dir::Down, Dir::First].get(code as usize).copied().unwrap_or(Dir::Last)
}

/// The browser's exports. One kernel per module instance.
#[cfg(target_arch = "wasm32")]
mod exports {
    use super::*;
    use crate::rows::Data;
    use core::cell::RefCell;

    std::thread_local! {
        static K: RefCell<Kernel> = RefCell::new(Kernel::new());
        static OUT: RefCell<Vec<u8>> = const { RefCell::new(Vec::new()) };
        /// The packed text cell `str_len` last read, `(table, col, id)` and
        /// its text, so the `str_ptr` that follows points into it.
        static TEXT: RefCell<Option<((u32, u32, u32), String)>> = const { RefCell::new(None) };
    }

    fn put(bytes: Vec<u8>) -> i32 {
        let n = bytes.len() as i32;
        OUT.with(|o| *o.borrow_mut() = bytes);
        n
    }

    fn put_json(j: &Json) -> i32 {
        put(j.to_string().into_bytes())
    }

    fn put_ids(ids: &[u32]) -> i32 {
        put(ids.iter().flat_map(|i| i.to_le_bytes()).collect())
    }

    /// A refusal's JSON, returned as minus its length minus one.
    fn refused(r: &Refusal) -> i32 {
        -put_json(&refusal_json(r)) - 1
    }

    /// # Safety
    /// `ptr` and `len` name a buffer from `alloc`, alive for the call.
    unsafe fn input<'a>(ptr: *const u8, len: usize) -> &'a [u8] {
        if len == 0 { &[] } else { unsafe { core::slice::from_raw_parts(ptr, len) } }
    }

    fn moved_json(m: &Moved) -> Json {
        let tables: serde_json::Map<String, Json> = m
            .tables
            .iter()
            .map(|(t, (w, g))| (t.to_string(), json!({"wrote": w, "gone": g})))
            .collect();
        json!({"tables": tables, "replaced": m.replaced})
    }

    /// Runs `f` under the JSON ctx `{today, now, human, key_id, held}`.
    fn with_ctx<R>(json: &[u8], f: impl FnOnce(&Ctx) -> R) -> R {
        let v: Json = serde_json::from_slice(json).unwrap_or(Json::Null);
        let held: Vec<u32> = v["held"].as_array().map(|a| a.iter().filter_map(|x| x.as_u64()).map(|x| x as u32).collect()).unwrap_or_default();
        f(&Ctx {
            today: v["today"].as_i64().unwrap_or(0) as Day,
            now: v["now"].as_i64().unwrap_or(0),
            human: v["human"].as_bool().unwrap_or(true),
            key_id: v["key_id"].as_u64().map(|x| x as u32),
            held: &held,
        })
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn alloc(len: usize) -> *mut u8 {
        let mut v = Vec::<u8>::with_capacity(len.max(1));
        let p = v.as_mut_ptr();
        core::mem::forget(v);
        p
    }

    /// # Safety
    /// `ptr`/`len` came from `alloc(len)` and are freed once.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn dealloc(ptr: *mut u8, len: usize) {
        drop(unsafe { Vec::from_raw_parts(ptr, 0, len.max(1)) });
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn result_ptr() -> *const u8 {
        OUT.with(|o| o.borrow().as_ptr())
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn wire_hash() -> u32 {
        schema::WIRE_HASH as u32
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn schema_rev() -> u32 {
        schema::SCHEMA_REV
    }

    /// The catalog JSON (`catalog_json`).
    #[unsafe(no_mangle)]
    pub extern "C" fn catalog() -> i32 {
        put_json(&catalog_json())
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn set_today(day: i32) {
        K.with(|k| k.borrow_mut().set_today(day));
    }

    /// One server frame. Result: `{tables: {id: {wrote, gone}}, replaced}`.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn ingest(ptr: *const u8, len: usize) -> i32 {
        let f = unsafe { input(ptr, len) };
        TEXT.with(|t| *t.borrow_mut() = None);
        K.with(|k| match k.borrow_mut().ingest(f) {
            Ok(m) => put_json(&moved_json(&m)),
            Err(_) => -1,
        })
    }

    /// Judges one op (OPS op layout) under a JSON ctx `{today, now,
    /// human, key_id, held}` and applies it as pending. Result: the moved
    /// JSON (returns its length), or the refusal JSON (returns minus its
    /// length minus one).
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn predict(op: *const u8, op_len: usize, ctx: *const u8, ctx_len: usize) -> i32 {
        let (op, c) = unsafe { (input(op, op_len), input(ctx, ctx_len)) };
        TEXT.with(|t| *t.borrow_mut() = None);
        with_ctx(c, |ctx| {
            K.with(|k| match k.borrow_mut().predict(op, ctx) {
                Ok(m) => put_json(&moved_json(&m)),
                Err(r) => refused(&r),
            })
        })
    }

    /// Only the verdict, nothing applied: the effects JSON (returns its
    /// length), or the refusal JSON (returns minus its length minus one).
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn judge(op: *const u8, op_len: usize, ctx: *const u8, ctx_len: usize) -> i32 {
        let (op, c) = unsafe { (input(op, op_len), input(ctx, ctx_len)) };
        with_ctx(c, |ctx| {
            K.with(|k| match k.borrow_mut().judge(op, ctx) {
                Ok(rows) => put_json(&effects_json(&rows)),
                Err(r) => refused(&r),
            })
        })
    }

    /// The session's grants from its WELCOME (masks over the five
    /// domains; `human` for the operator's browser session).
    #[unsafe(no_mangle)]
    pub extern "C" fn set_grants(read_mask: u32, write_mask: u32, may_delete: u32, human: u32) {
        let grants = query::Grants { human: human == 1, read_mask: read_mask as u8, write_mask: write_mask as u8, may_delete: may_delete == 1 };
        K.with(|k| k.borrow_mut().set_grants(grants));
    }

    /// A read of the replica (`query::query`): the answer JSON (returns its
    /// length), or the refusal JSON (returns minus its length minus one).
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn query(ptr: *const u8, len: usize) -> i32 {
        let req = serde_json::from_slice(unsafe { input(ptr, len) }).unwrap_or(Json::Null);
        K.with(|k| match k.borrow_mut().query(&req) {
            Ok(j) => put_json(&j),
            Err(r) => refused(&r),
        })
    }

    thread_local! {
        static GROUPS: RefCell<Json> = const { RefCell::new(Json::Null) };
    }

    /// The board's filtered order sorted and grouped: the ids land as u32s
    /// like `view`'s; `arrange_groups` answers their groups.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn arrange(ptr: *const u8, len: usize) -> i32 {
        let req: Json = serde_json::from_slice(unsafe { input(ptr, len) }).unwrap_or(Json::Null);
        K.with(|k| match k.borrow_mut().arrange(&req) {
            Ok((ids, groups)) => {
                GROUPS.with(|g| *g.borrow_mut() = groups);
                put_ids(&ids)
            }
            Err(r) => refused(&r),
        })
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn arrange_groups() -> i32 {
        GROUPS.with(|g| put_json(&g.borrow()))
    }

    /// Board ids (u32 LE) a JSON filter keeps, in order.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn view(ptr: *const u8, len: usize) -> i32 {
        let f = filter(core::str::from_utf8(unsafe { input(ptr, len) }).unwrap_or("{}"));
        K.with(|k| put_ids(&k.borrow_mut().view(&f)))
    }

    /// The card after `selected` (0 = none) in `dir` (0 next, 1 prev, 2
    /// up, 3 down, 4 first, 5 last) over the filtered view; 0 for none.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn step(ptr: *const u8, len: usize, selected: u32, d: u32, columns: u32) -> u32 {
        let f = filter(core::str::from_utf8(unsafe { input(ptr, len) }).unwrap_or("{}"));
        K.with(|k| {
            let v = k.borrow_mut().view(&f);
            crate::board::step(&v, (selected != 0).then_some(selected), dir(d), columns as usize).unwrap_or(0)
        })
    }

    /// One card as JSON `{score_100, stored, band, class, stage, ratio, reason}`.
    #[unsafe(no_mangle)]
    pub extern "C" fn card(id: u32) -> i32 {
        K.with(|k| {
            let mut k = k.borrow_mut();
            match k.board().card(id) {
                Some(c) => put_json(&json!({
                    "score_100": c.score, "stored": c.stored, "band": c.band.name(), "class": c.class.name(),
                    "stage": c.stage.name(), "ratio": c.verdict.ratio(), "reason": c.verdict.reason.name(),
                })),
                None => -1,
            }
        })
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn scoreboard() -> i32 {
        K.with(|k| {
            let mut k = k.borrow_mut();
            let today = k.today();
            k.derive();
            let s = k.board.scoreboard(&k.rows, today);
            put_json(&s.to_json())
        })
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn application(id: u32) -> i32 {
        K.with(|k| k.borrow_mut().application(id).map_or(-1, |j| put_json(&j)))
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn overview(top: u32) -> i32 {
        K.with(|k| put_json(&k.borrow_mut().overview(top as usize)))
    }

    /// Every country and city in the person's order.
    #[unsafe(no_mangle)]
    pub extern "C" fn atlas() -> i32 {
        K.with(|k| put_json(&k.borrow().atlas()))
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn snapshot() -> i32 {
        K.with(|k| put(k.borrow().snapshot()))
    }

    /// Restores a snapshot; returns 0, or -1 for one of another schema.
    #[unsafe(no_mangle)]
    pub unsafe extern "C" fn restore(ptr: *const u8, len: usize) -> i64 {
        let s = unsafe { input(ptr, len) };
        TEXT.with(|t| *t.borrow_mut() = None);
        K.with(|k| k.borrow_mut().restore(s).map_or(-1, |rev| rev as i64))
    }

    /// `f` over one of the kernel's tables, if it holds it.
    fn table<R>(t: u32, f: impl FnOnce(Option<&crate::rows::Table>) -> R) -> R {
        K.with(|k| f(k.borrow().rows.table(t as u16)))
    }

    /// Row count of a table.
    #[unsafe(no_mangle)]
    pub extern "C" fn rows(t: u32) -> u32 {
        table(t, |t| t.map_or(0, |t| t.len() as u32))
    }

    /// The table's ids, `rows(t)` u32s in slot order.
    #[unsafe(no_mangle)]
    pub extern "C" fn ids_ptr(t: u32) -> *const u32 {
        table(t, |t| t.map_or(core::ptr::null(), |t| t.ids().as_ptr()))
    }

    /// A column's storage in slot order: u32 (kind 1), i64 (3) or f64
    /// (4) values, `rows(t)` of them; null for other kinds.
    #[unsafe(no_mangle)]
    pub extern "C" fn col_ptr(t: u32, c: u32) -> *const u8 {
        table(t, |t| match t.and_then(|t| t.column(c as u16)).map(|c| &c.data) {
            Some(Data::U32(v)) => v.as_ptr() as *const u8,
            Some(Data::I64(v)) => v.as_ptr() as *const u8,
            Some(Data::F64(v)) => v.as_ptr() as *const u8,
            _ => core::ptr::null(),
        })
    }

    /// A column's storage kind: 1 u32, 2 str (packed text too: `str_len`
    /// and `str_ptr` unpack it), 3 i64, 4 f64, 7 list; 0 when absent.
    #[unsafe(no_mangle)]
    pub extern "C" fn col_kind(t: u32, c: u32) -> u32 {
        table(t, |t| match t.and_then(|t| t.column(c as u16)).map(|c| &c.data) {
            Some(Data::U32(_)) => 1,
            Some(Data::Str(_) | Data::Packed(_)) => 2,
            Some(Data::I64(_)) => 3,
            Some(Data::F64(_)) => 4,
            Some(Data::List(_)) => 7,
            None => 0,
        })
    }

    /// The string at `(table, col, row id)`: pointer, with its length from
    /// `str_len`. Empty (null) is length 0.
    #[unsafe(no_mangle)]
    pub extern "C" fn str_ptr(t: u32, c: u32, id: u32) -> *const u8 {
        cell(t, c, id, |s| s.as_ptr()).unwrap_or(core::ptr::null())
    }

    #[unsafe(no_mangle)]
    pub extern "C" fn str_len(t: u32, c: u32, id: u32) -> u32 {
        cell(t, c, id, |s| s.len() as u32).unwrap_or(0)
    }

    /// A str cell in place, or a packed one unpacked into TEXT (kept for the
    /// call after it): what `str_len` and `str_ptr` read.
    fn cell<R>(t: u32, c: u32, id: u32, f: impl Fn(&str) -> R) -> Option<R> {
        table(t, |table| {
            let table = table?;
            if let Some(s) = table.str(id, c as u16) {
                return Some(f(s));
            }
            TEXT.with(|text| {
                let mut text = text.borrow_mut();
                if text.as_ref().is_none_or(|(key, _)| *key != (t, c, id)) {
                    *text = table.text(id, c as u16).map(|s| ((t, c, id), s.into_owned()));
                }
                text.as_ref().map(|(_, s)| f(s))
            })
        })
    }

    /// The slot of a row id in its table's column views; `u32::MAX` if absent.
    #[unsafe(no_mangle)]
    pub extern "C" fn slot(t: u32, id: u32) -> u32 {
        table(t, |t| t.and_then(|t| t.slot(id)).map_or(u32::MAX, |s| s as u32))
    }
}
