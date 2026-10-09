//! The WebAssembly export ABI, built only for wasm32.
//!
//! The browser keeps the whole desk resident in this module's memory: the
//! account's raw tables, the views derived from them, and the ops in
//! flight. Frames go in through one buffer; TypeScript reads columns
//! straight out of memory by pointer. This file is the export ABI and
//! nothing else: `store` holds the tables, `desk` the pending view, order
//! and selection, `predict` the ops, `derive` the views, `heat` and
//! `keywords` the Elixir ports they run.
//!
//! ABI conventions. Every argument and result is an i32/u32. Pointers are
//! byte offsets into the exported `memory`; a pointer stays valid until
//! the next call that mutates the kernel (ingest, push, select, snapshot),
//! after which views must be taken again because memory may have grown.
//! Tables and columns are named by their schema ids (`col_id` resolves a
//! name), and every table, the cards included, is read the same way:
//!
//! - `rows(t)`; `col_ptr(t, c)` → u32 words, u64/f64 words, or for a str
//!   column `(offset, len)` u32 pairs into `arena_ptr()`; `col_type(t, c)`
//!   (0 when absent); `str_ptr(t, c, row)` / `str_len(t, c, row)` (0 for
//!   an absent or empty value, so a draw needs no branch); `row_of(t, key)`.
//! - Raw tables read through the pending view (base ⊕ pending ops); the
//!   derived tables (cards, verdicts, heat_rows, score...) are re-derived
//!   from that view by `derive()`, which ingest and select also run.
//!
//! Ingest: `ingest_reserve(len)` → ptr, copy whole frames there, then
//! `ingest_commit(len)` → a [`changed`] bitmask. ACK and NACK frames settle
//! the pending layer inside ingest; what settled is in `events_*`.

use alloc::vec::Vec;
use core::cell::UnsafeCell;

use crate::desk::Desk;
use crate::store;
use wire::schema;

struct Kernel {
    desk: Desk,
    ingest: Vec<u8>,
    scratch: Vec<u8>,
    snapshot: Vec<u8>,
}

/// The one kernel. WebAssembly here is single-threaded and no export
/// calls back into JavaScript, so exports never overlap and each takes the
/// state for the length of its own call only.
struct Global(UnsafeCell<Kernel>);

// SAFETY: wasm32-unknown-unknown without the atomics feature has one
// thread; nothing else can observe the cell.
unsafe impl Sync for Global {}

static K: Global = Global(UnsafeCell::new(Kernel {
    desk: Desk::new(),
    ingest: Vec::new(),
    scratch: Vec::new(),
    snapshot: Vec::new(),
}));

fn with<R>(f: impl FnOnce(&mut Kernel) -> R) -> R {
    // SAFETY: see `Global`; `with` is never re-entered, since no export
    // calls another.
    f(unsafe { &mut *K.0.get() })
}

fn reserve(v: &mut Vec<u8>, len: u32) -> u32 {
    v.clear();
    v.resize(len as usize, 0);
    v.as_mut_ptr() as u32
}

impl Kernel {
    /// The column a reader sees: the pending view.
    fn col(&self, t: u16, c: u16) -> Option<&store::Column> {
        self.desk.view_col(t, c)
    }

    fn rows(&self, t: u16) -> u32 {
        self.desk.rows(t) as u32
    }

    fn str_ref(&self, t: u16, c: u16, row: u32) -> [u32; 2] {
        self.col(t, c).map_or([0, 0], |c| c.str_ref(row as usize))
    }
}

// ---- schema -----------------------------------------------------------

#[unsafe(no_mangle)]
pub extern "C" fn schema_hash() -> u32 {
    schema::HASH as u32
}

/// A general-purpose input buffer for names, queries and ops.
#[unsafe(no_mangle)]
pub extern "C" fn scratch(len: u32) -> u32 {
    with(|k| reserve(&mut k.scratch, len))
}

fn scratch_str(k: &Kernel, len: u32) -> &str {
    core::str::from_utf8(k.scratch.get(..len as usize).unwrap_or(&[])).unwrap_or("")
}

/// Table id for the name in scratch, or -1.
#[unsafe(no_mangle)]
pub extern "C" fn table_id(len: u32) -> i32 {
    with(|k| schema::table_id(scratch_str(k, len)).map_or(-1, i32::from))
}

/// Column id for the name in scratch within table `t`, or -1.
#[unsafe(no_mangle)]
pub extern "C" fn col_id(t: u32, len: u32) -> i32 {
    with(|k| schema::col_id(t as u16, scratch_str(k, len)).map_or(-1, i32::from))
}

// ---- ingest -----------------------------------------------------------

#[unsafe(no_mangle)]
pub extern "C" fn ingest_reserve(len: u32) -> u32 {
    with(|k| reserve(&mut k.ingest, len))
}

#[unsafe(no_mangle)]
pub extern "C" fn ingest_commit(len: u32) -> u32 {
    with(|k| {
        let buf = core::mem::take(&mut k.ingest);
        let bits = k.desk.ingest(&buf[..(len as usize).min(buf.len())]);
        k.ingest = buf;
        bits
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn rev_lo() -> u32 {
    with(|k| k.desk.store.rev as u32)
}

#[unsafe(no_mangle)]
pub extern "C" fn rev_hi() -> u32 {
    with(|k| (k.desk.store.rev >> 32) as u32)
}

#[unsafe(no_mangle)]
pub extern "C" fn set_today(day: u32) {
    with(|k| k.desk.today = day)
}

#[unsafe(no_mangle)]
pub extern "C" fn today() -> u32 {
    with(|k| k.desk.today)
}

// ---- tables -----------------------------------------------------------

#[unsafe(no_mangle)]
pub extern "C" fn rows(t: u32) -> u32 {
    with(|k| k.rows(t as u16))
}

#[unsafe(no_mangle)]
pub extern "C" fn col_ptr(t: u32, c: u32) -> u32 {
    with(|k| k.col(t as u16, c as u16).map_or(0, |c| c.ptr() as u32))
}

#[unsafe(no_mangle)]
pub extern "C" fn col_type(t: u32, c: u32) -> u32 {
    with(|k| k.col(t as u16, c as u16).map_or(0, |c| c.ty as u32))
}

#[unsafe(no_mangle)]
pub extern "C" fn str_ptr(t: u32, c: u32, row: u32) -> u32 {
    with(|k| {
        let r = k.str_ref(t as u16, c as u16, row);
        k.desk.store.arena.bytes.as_ptr() as u32 + r[0]
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn str_len(t: u32, c: u32, row: u32) -> u32 {
    with(|k| k.str_ref(t as u16, c as u16, row)[1])
}

/// Row of `key` in a table, or -1: by id for the keyed tables, by the
/// first column for any other.
#[unsafe(no_mangle)]
pub extern "C" fn row_of(t: u32, key: u32) -> i32 {
    with(|k| k.desk.row_of(t as u16, key).map_or(-1, |r| r as i32))
}

// ---- board ------------------------------------------------------------

/// Selects cards in board order. The query is `qlen` bytes in scratch.
#[unsafe(no_mangle)]
#[allow(clippy::too_many_arguments)]
pub extern "C" fn select(
    min: i32,
    lo: i32,
    hi: i32,
    stage: i32,
    status: i32,
    batch: i32,
    profile: i32,
    heat: i32,
    qlen: u32,
) -> u32 {
    with(|k| {
        let q = k.scratch.get(..qlen as usize).unwrap_or(&[]).to_vec();
        k.desk
            .select(min, lo, hi, stage, status, batch, profile, heat, &q) as u32
    })
}

/// Re-derives every local view (cards, verdicts, heat chart, scoreboard)
/// if the raw tables or the pending view moved; ingest and select do this
/// themselves. Returns 1 when it ran.
#[unsafe(no_mangle)]
pub extern "C" fn derive() -> u32 {
    with(|k| k.desk.derive() as u32)
}

/// Keywords coverage for a CV: scratch holds the visible text (`text_len`
/// bytes) followed by the theme's targets joined by U+001F (`targets_len`
/// bytes; 0 means Keywords.extract of the job's listing). Fills the
/// `coverage` table and returns the hit count. (Cards count their own
/// hits; this is for a focus and its root.)
#[unsafe(no_mangle)]
pub extern "C" fn coverage(job: u32, text_len: u32, targets_len: u32) -> u32 {
    with(|k| {
        let s = core::mem::take(&mut k.scratch);
        let t = (text_len as usize).min(s.len());
        let g = (t + targets_len as usize).min(s.len());
        let n = k.desk.coverage(job, &s[..t], &s[t..g]);
        k.scratch = s;
        n
    })
}

/// Heat.mix_batch of one batch (read-only) into the `mix` table.
#[unsafe(no_mangle)]
pub extern "C" fn mix(batch: u32) -> u32 {
    with(|k| k.desk.mix(batch))
}

/// Runs the kernel over a small made-up board and forgets it, so the
/// first BOOT does not pay the browser's lazy compile. Call it once after
/// instantiating, before any frame.
#[unsafe(no_mangle)]
pub extern "C" fn warm() {
    with(|k| k.desk.warm())
}

/// The selection: card rows (u32), in board order; `select` answers its length.
#[unsafe(no_mangle)]
pub extern "C" fn selection_ptr() -> u32 {
    with(|k| k.desk.sel.as_ptr() as u32)
}

/// Position of a job id in the selection, or -1.
#[unsafe(no_mangle)]
pub extern "C" fn find(id: u32) -> i32 {
    with(|k| k.desk.find(id))
}

// ---- pending ----------------------------------------------------------

/// Predicts the OP body (`len` bytes in scratch). 0: applied to the view,
/// send it. Otherwise the refusal code the server would give; nothing
/// changed and the op should not be sent.
#[unsafe(no_mangle)]
pub extern "C" fn pending_push(len: u32) -> u32 {
    with(|k| {
        let bytes = k.scratch.get(..len as usize).unwrap_or(&[]).to_vec();
        k.desk.push(&bytes) as u32
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn pending_count() -> u32 {
    with(|k| k.desk.pending_count() as u32)
}

/// (table, key) pairs of the rows the last ingest_commit or pending_push
/// wrote or deleted, raw and derived alike; key 0xFFFFFFFF is the whole
/// table and (0xFFFFFFFF, 0xFFFFFFFF) is everything (a BOOT).
#[unsafe(no_mangle)]
pub extern "C" fn touched_len() -> u32 {
    with(|k| k.desk.touched.len() as u32)
}

/// The touched pairs as u32 (table, key) pairs.
#[unsafe(no_mangle)]
pub extern "C" fn touched_ptr() -> u32 {
    with(|k| k.desk.touched.as_ptr() as u32)
}

/// In-memory counters: 0 predicted, 1 settled exactly, 2 mispredicted,
/// 3 refused by the server, 4 refused locally, 5 unknown ACKs, 6 bad
/// frames, 7 arena compactions.
#[unsafe(no_mangle)]
pub extern "C" fn counter(i: u32) -> u32 {
    with(|k| k.desk.counters.get(i as usize).copied().unwrap_or(0))
}

// ---- snapshot ---------------------------------------------------------

/// Encodes the resident raw tables (base, not the pending view) as one
/// BOOT frame. Returns the length; `snapshot_ptr` the bytes. Ingesting it
/// into a fresh kernel restores this one, views derived again.
#[unsafe(no_mangle)]
pub extern "C" fn snapshot() -> u32 {
    with(|k| {
        let mut w = wire::Writer::new();
        w.buf = core::mem::take(&mut k.snapshot);
        w.buf.clear();
        k.desk.store.snapshot(&mut w);
        k.snapshot = w.buf;
        k.snapshot.len() as u32
    })
}

#[unsafe(no_mangle)]
pub extern "C" fn snapshot_ptr() -> u32 {
    with(|k| k.snapshot.as_ptr() as u32)
}

// ---- the runtime --------------------------------------------------------
//
// Without std the module carries no formatting, no panic machinery and no
// general-purpose malloc: a panic is a trap, and memory comes from a
// size-class allocator below. That is most of the binary's former size.

#[cfg(target_arch = "wasm32")]
#[panic_handler]
fn panic(_: &core::panic::PanicInfo) -> ! {
    core::arch::wasm32::unreachable()
}

#[cfg(target_arch = "wasm32")]
#[global_allocator]
static HEAP: heap::Heap = heap::Heap::new();

/// Power-of-two size classes from 16 bytes up, each with a free list,
/// carved from a bump pointer that grows linear memory a page run at a
/// time. A freed block goes back to its class; a realloc within the same
/// class returns the same block. Vectors double, so their blocks are
/// already powers of two and lose nothing to the rounding.
#[cfg(target_arch = "wasm32")]
mod heap {
    use core::alloc::{GlobalAlloc, Layout};
    use core::arch::wasm32;
    use core::cell::UnsafeCell;
    use core::ptr;

    const CLASSES: usize = 32;
    const PAGE: usize = 65536;

    struct State {
        free: [usize; CLASSES],
        top: usize,
        end: usize,
    }

    pub struct Heap(UnsafeCell<State>);

    // SAFETY: one thread, as for the kernel state.
    unsafe impl Sync for Heap {}

    impl Heap {
        pub const fn new() -> Heap {
            Heap(UnsafeCell::new(State {
                free: [0; CLASSES],
                top: 0,
                end: 0,
            }))
        }
    }

    unsafe extern "C" {
        static __heap_base: u8;
    }

    fn class(l: &Layout) -> Option<usize> {
        if l.align() > 16 {
            return None;
        }
        let size = l.size().max(16).checked_next_power_of_two()?;
        let c = size.trailing_zeros() as usize;
        (c < CLASSES).then_some(c)
    }

    unsafe impl GlobalAlloc for Heap {
        unsafe fn alloc(&self, l: Layout) -> *mut u8 {
            let Some(c) = class(&l) else {
                return ptr::null_mut();
            };
            // SAFETY: single-threaded; see the impl Sync above.
            let s = unsafe { &mut *self.0.get() };
            let head = s.free[c];
            if head != 0 {
                // SAFETY: a free block holds the address of the next one.
                s.free[c] = unsafe { *(head as *const usize) };
                return head as *mut u8;
            }
            if s.top == 0 {
                let base = ptr::addr_of!(__heap_base) as usize;
                s.top = (base + 15) & !15;
                s.end = wasm32::memory_size(0) * PAGE;
            }
            let size = 1usize << c;
            let want = s.top + size;
            if want > s.end {
                let pages = (want - s.end).div_ceil(PAGE);
                if wasm32::memory_grow(0, pages) == usize::MAX {
                    return ptr::null_mut();
                }
                s.end += pages * PAGE;
            }
            let p = s.top;
            s.top = want;
            p as *mut u8
        }

        unsafe fn dealloc(&self, p: *mut u8, l: Layout) {
            let Some(c) = class(&l) else { return };
            // SAFETY: single-threaded; the block is at least 16 bytes and
            // 16-aligned, so it can hold the free-list link.
            let s = unsafe { &mut *self.0.get() };
            unsafe { *(p as *mut usize) = s.free[c] };
            s.free[c] = p as usize;
        }

        unsafe fn realloc(&self, p: *mut u8, l: Layout, new: usize) -> *mut u8 {
            // SAFETY: same alignment, and `new` is nonzero by contract.
            let nl = unsafe { Layout::from_size_align_unchecked(new, l.align()) };
            if class(&l).is_some() && class(&l) == class(&nl) {
                return p;
            }
            // SAFETY: the GlobalAlloc contract, as the default realloc.
            unsafe {
                let q = self.alloc(nl);
                if !q.is_null() {
                    ptr::copy_nonoverlapping(p, q, l.size().min(new));
                    self.dealloc(p, l);
                }
                q
            }
        }
    }
}
