;; The desk's resident column store.
;;
;; Memory holds one HDP1 packet body and a selection. Columns are u32
;; arrays or (offsets, bytes) string arenas. `select` writes the row
;; indices that pass every filter into an output array, in packet
;; order, which is board order. Nothing here knows what a job is: it
;; compares columns the packet directory named.
;;
;; Column table (u32 pointers, written by the shell at `cols`):
;;   0 score   1 heat   2 stage   3 status   4 freshness   5 gate
;;   6 batch (0 = none, else ordinal+1)   7 profile
;;   8 search offsets (n+1 u32)   9 search bytes
;;
;; Filter conventions: -1 means "all". `batch` -2 means "no batch".
(module
  (memory (export "mem") 32)

  (global $heap (mut i32) (i32.const 1024))

  (func (export "reset")
    (global.set $heap (i32.const 1024)))

  ;; Bump allocation, 4-byte aligned, growing memory as needed.
  (func (export "alloc") (param $size i32) (result i32)
    (local $ptr i32)
    (local $pages i32)
    (local $have i32)
    (local.set $ptr (global.get $heap))
    (local.set $size (i32.and (i32.add (local.get $size) (i32.const 3)) (i32.const -4)))
    (global.set $heap (i32.add (local.get $ptr) (local.get $size)))
    (local.set $pages (i32.shr_u (i32.add (global.get $heap) (i32.const 65535)) (i32.const 16)))
    (local.set $have (memory.size))
    (if (i32.gt_u (local.get $pages) (local.get $have))
      (then
        (if (i32.eq (memory.grow (i32.sub (local.get $pages) (local.get $have))) (i32.const -1))
          (then unreachable))))
    (local.get $ptr))

  (func $col (param $cols i32) (param $k i32) (result i32)
    (i32.load (i32.add (local.get $cols) (i32.shl (local.get $k) (i32.const 2)))))

  (func $at (param $base i32) (param $i i32) (result i32)
    (i32.load (i32.add (local.get $base) (i32.shl (local.get $i) (i32.const 2)))))

  ;; Does row $i's search text contain the $qlen bytes at $q?
  (func $contains (param $offs i32) (param $bytes i32) (param $i i32) (param $q i32) (param $qlen i32) (result i32)
    (local $start i32)
    (local $end i32)
    (local $j i32)
    (local $k i32)
    (local.set $start (call $at (local.get $offs) (local.get $i)))
    (local.set $end (call $at (local.get $offs) (i32.add (local.get $i) (i32.const 1))))
    (if (i32.lt_u (i32.sub (local.get $end) (local.get $start)) (local.get $qlen))
      (then (return (i32.const 0))))
    (local.set $end (i32.sub (local.get $end) (local.get $qlen)))
    (local.set $j (local.get $start))
    (block $done
      (loop $outer
        (br_if $done (i32.gt_u (local.get $j) (local.get $end)))
        (local.set $k (i32.const 0))
        (block $miss
          (loop $inner
            (br_if $miss
              (i32.ne
                (i32.load8_u (i32.add (local.get $bytes) (i32.add (local.get $j) (local.get $k))))
                (i32.load8_u (i32.add (local.get $q) (local.get $k)))))
            (local.set $k (i32.add (local.get $k) (i32.const 1)))
            (br_if $inner (i32.lt_u (local.get $k) (local.get $qlen))))
          (return (i32.const 1)))
        (local.set $j (i32.add (local.get $j) (i32.const 1)))
        (br $outer)))
    (i32.const 0))

  ;; Row indices that pass every filter, written to $out. Returns count.
  (func (export "select")
    (param $n i32) (param $cols i32)
    (param $min i32) (param $lo i32) (param $hi i32)
    (param $stage i32) (param $status i32) (param $batch i32) (param $profile i32)
    (param $q i32) (param $qlen i32)
    (param $out i32)
    (result i32)
    (local $i i32)
    (local $count i32)
    (local $score i32)
    (local $b i32)
    (local $c_score i32) (local $c_stage i32) (local $c_status i32) (local $c_batch i32) (local $c_profile i32)
    (local $c_offs i32) (local $c_bytes i32)
    (local.set $c_score (call $col (local.get $cols) (i32.const 0)))
    (local.set $c_stage (call $col (local.get $cols) (i32.const 2)))
    (local.set $c_status (call $col (local.get $cols) (i32.const 3)))
    (local.set $c_batch (call $col (local.get $cols) (i32.const 6)))
    (local.set $c_profile (call $col (local.get $cols) (i32.const 7)))
    (local.set $c_offs (call $col (local.get $cols) (i32.const 8)))
    (local.set $c_bytes (call $col (local.get $cols) (i32.const 9)))
    (block $end
      (loop $rows
        (br_if $end (i32.ge_u (local.get $i) (local.get $n)))
        (block $skip
          (local.set $score (call $at (local.get $c_score) (local.get $i)))
          (br_if $skip (i32.lt_s (local.get $score) (local.get $min)))
          (br_if $skip (i32.lt_s (local.get $score) (local.get $lo)))
          (br_if $skip (i32.gt_s (local.get $score) (local.get $hi)))
          (if (i32.ne (local.get $stage) (i32.const -1))
            (then (br_if $skip (i32.ne (call $at (local.get $c_stage) (local.get $i)) (local.get $stage)))))
          (if (i32.ne (local.get $status) (i32.const -1))
            (then (br_if $skip (i32.ne (call $at (local.get $c_status) (local.get $i)) (local.get $status)))))
          (if (i32.ne (local.get $profile) (i32.const -1))
            (then (br_if $skip (i32.ne (call $at (local.get $c_profile) (local.get $i)) (local.get $profile)))))
          (local.set $b (call $at (local.get $c_batch) (local.get $i)))
          (if (i32.eq (local.get $batch) (i32.const -2))
            (then (br_if $skip (i32.ne (local.get $b) (i32.const 0))))
            (else
              (if (i32.ne (local.get $batch) (i32.const -1))
                (then (br_if $skip (i32.ne (local.get $b) (local.get $batch)))))))
          (if (i32.gt_u (local.get $qlen) (i32.const 0))
            (then
              (br_if $skip
                (i32.eqz
                  (call $contains (local.get $c_offs) (local.get $c_bytes) (local.get $i)
                    (local.get $q) (local.get $qlen))))))
          (i32.store (i32.add (local.get $out) (i32.shl (local.get $count) (i32.const 2))) (local.get $i))
          (local.set $count (i32.add (local.get $count) (i32.const 1))))
        (local.set $i (i32.add (local.get $i) (i32.const 1)))
        (br $rows)))
    (local.get $count))

  ;; Position of the row whose u32 in column $ids equals $id within the
  ;; selection at $out, or -1.
  (func (export "find") (param $out i32) (param $count i32) (param $ids i32) (param $id i32) (result i32)
    (local $p i32)
    (block $none
      (loop $scan
        (br_if $none (i32.ge_u (local.get $p) (local.get $count)))
        (if (i32.eq (call $at (local.get $ids) (call $at (local.get $out) (local.get $p))) (local.get $id))
          (then (return (local.get $p))))
        (local.set $p (i32.add (local.get $p) (i32.const 1)))
        (br $scan)))
    (i32.const -1))
)
