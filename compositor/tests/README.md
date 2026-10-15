# Drawing and resize regressions

From `compositor/`:

```sh
cargo test
xcrun clang -fobjc-arc -Wall -framework AppKit -framework QuartzCore \
  -framework IOSurface -framework Foundation \
  -o /tmp/vzcomp-presentation tests/presentation.m
/tmp/vzcomp-presentation
cargo build --release
python3 tests/wayland-stress.py target/release/vzcomp
```

The native test retains 120 submitted frames before presentation and verifies
that subsequent uploads never alter them. The original IOSurface pool fails this
assertion on the third upload: `IOSurfaceIsInUse` can be false before Core
Animation/WindowServer acquires a queued frame. Published surfaces are now
immutable; Core Animation owns their lifetime. This trades per-frame allocation
for correctness. The test also exercises 240 changing buffer sizes, padded
strides, XRGB alpha, clearing, and the native interactive-resize guard.

The Python test launches an isolated compositor child using a socketpair and
speaks Wayland directly. It submits 200 changing-size frames in bursts of ten,
uses distinct SHM storage for outstanding commits, waits for 20 display
callbacks, and checks protocol errors and clean disconnect. It briefly opens
its own native test window; no running VM or application needs to stop.

Rust tests check that older committed configure serials cannot undo newer host
sizes (including serial wraparound), and that reentrant AppKit callbacks queue
instead of borrowing the active compositor again. Host geometry is adopted only
on root commits after the newest resize configure has been committed. The
Wayland FD stays disabled until deferred dispatch actually consumes its data.

Diagnosis on 2026-10-15: all 109 existing `/tmp/vzdump` captures exactly matched
saved sommelier destination frames in the guest, and complete guest source /
destination pairs matched too. That supports investigating host presentation;
it does not prove every possible guest rendering artifact is resolved. The
guest `/tmp` was full of diagnostic dumps, so long capture runs should use a
bounded capture directory. Existing captures were preserved.

These checks cover copying, ordering, native sizing, and protocol dispatch.
Interactive visual verification through the running guest remains a separate
check. Already-running compositor children retain their old code; reopen the
Linux app to use the rebuilt compositor.
