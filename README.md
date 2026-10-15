# cl-ghostty-vt

Common Lisp bindings to **libghostty-vt**, the terminal-emulation core of
[Ghostty](https://github.com/ghostty-org/ghostty), via CFFI.

Feed it the bytes a program writes to a pty and query the result: the grid of
cells (grapheme clusters, width, colors, attributes), the cursor, the title, and
the replies the terminal owes the program (device attributes, cursor reports).
It also encodes key presses into the byte sequences the program expects.
Rendering, fonts and pty handling are left to you.

> **Stability warning.** libghostty-vt has no stable ABI yet; the Ghostty
> project changes it freely. These bindings target one pinned Ghostty commit
> and check struct sizes against the library when they load. Expect breaking
> changes in this library too until the upstream API settles.

## Pinned versions

| Component | Version |
|-----------|---------|
| Ghostty   | [`22fa134a07f5749edd9e92c6bc17d8aaf61843be`](https://github.com/ghostty-org/ghostty/tree/22fa134a07f5749edd9e92c6bc17d8aaf61843be) |
| Zig       | 0.16.0 (newer Zig versions cannot build this commit) |

## Building the library

```sh
scripts/build-libghostty-vt.sh
```

The script:

1. downloads Zig 0.16.0 for Linux (x86_64, aarch64) or macOS (arm64, x86_64)
   and checks it against the SHA-256 published in ziglang.org's
   `download/index.json`;
2. shallow-fetches the pinned Ghostty commit;
3. runs `zig build -Demit-lib-vt=true -Doptimize=ReleaseFast` and installs the
   library and headers into `build/` (`build/lib`, `build/include/ghostty`);
4. compiles `csrc/ghostty-vt-cl.c` with `zig cc` into
   `build/lib/libghostty-vt-cl.{so,dylib}` (see *By-value structs* below).

Downloads and Zig caches live in `.deps/`. Both `.deps/` and `build/` are
git-ignored. Running the script again skips any step that is already done.
`FORCE=1` rebuilds everything. You can also set `GHOSTTY_COMMIT`,
`GHOSTTY_REPO`, `ZIG` (an existing 0.16 binary) and `OPTIMIZE`.

You need `git`, `curl` (or `wget`), `tar` with xz support and a POSIX shell.

### Where the Lisp side looks for the library

1. `$GHOSTTY_VT_LIBRARY`: either the library file or a directory that contains it;
2. `build/lib/` inside this system's directory;
3. the platform's default search path (`libghostty-vt.so` / `.dylib`).

The optional shim is looked up in `$GHOSTTY_VT_SHIM_LIBRARY`, then next to the
loaded libghostty-vt, then in `build/lib/`.

## Loading and testing

```lisp
(asdf:load-system "ghostty-vt")
(asdf:test-system "ghostty-vt")   ; or (ghostty-vt/tests:run-tests)
```

Dependencies: `cffi`, `cffi-libffi` (which needs the libffi headers when it is
compiled) and `bordeaux-threads`. The tests also use `babel`.

## API overview

All of these are in the `ghostty-vt` package. Rows and columns are zero-based
and count from the top-left of the active screen.

```lisp
(ghostty-vt:with-terminal (term :rows 24 :columns 80
                                :on-pty-write (lambda (octets) (write-to-pty octets))
                                :on-bell (lambda () (beep))
                                :on-title (lambda (title) (set-window-title title)))
  (ghostty-vt:terminal-feed term (format nil "~C[1;31mhi~C[0m" #\Esc #\Esc))
  (ghostty-vt:terminal-cell term 0 0)
  ;; => #S(CELL :CODEPOINTS (104) :WIDTH :NARROW :FG (:PALETTE 1) :BG (:DEFAULT) :ATTRS (:BOLD))
  (ghostty-vt:terminal-cursor term)        ; => 0, 2, T   (row col visible-p)
  (ghostty-vt:encode-key term :up))        ; => #(27 91 65)
```

**Lifecycle**

- `make-terminal &key rows columns on-pty-write on-bell on-title` creates a terminal.
- `terminal-free` releases it; calling it twice is safe.
- `with-terminal` creates a terminal and frees it when the body exits.
- `terminal-live-p` tells you whether a terminal has been freed.

**Input**

- `terminal-feed term data &key start end` takes a string (sent as UTF-8) or an octet vector.
- `terminal-reset` does a full reset (RIS).
- `terminal-resize term rows columns &key cell-width-px cell-height-px`.

**State**

- `terminal-rows` and `terminal-columns` give the size.
- `terminal-cursor` returns `(values row col visible-p)`.
- `terminal-title`, `terminal-active-screen` (`:primary` or `:alternate`).
- `terminal-mode term n &key ansi` tells you whether DEC private mode `n` is
  set. With `:ansi t`, it checks ANSI mode `n` instead.

**Cells and text**

- `terminal-cell term row col` returns a `cell` struct with these accessors:
  - `cell-codepoints`: the code points of the grapheme cluster, as a list;
  - `cell-string`;
  - `cell-width`: `:narrow`, `:wide`, `:spacer-tail` or `:spacer-head`;
  - `cell-fg` and `cell-bg`: `(:default)`, `(:palette n)` or `(:rgb r g b)`;
  - `cell-attrs`: any of `:bold :italic :faint :blink :inverse :invisible :strike :overline`, plus one of
    `:underline :double-underline :curly-underline :dotted-underline :dashed-underline`.
- `terminal-row-text term row &key trim` shows each wide character once. Blank cells
  become spaces.
- `terminal-screen-text term &key trim unwrap format` formats the whole screen,
  scrollback included, with libghostty-vt's own formatter. `format` is `:plain`,
  `:vt` or `:html`.

**Callbacks**

- `terminal-pty-write-function` receives an octet vector.
- `terminal-bell-function` takes no arguments.
- `terminal-title-function` receives the new title.

All three are `setf`-able. They run synchronously inside `terminal-feed` and
must not feed the same terminal again. An error in a callback can't unwind
through C, so it is caught and `terminal-feed` signals it again once the parse
has finished. Each terminal registers itself under an integer id, which libghostty-vt passes back as the
callback userdata. That means any number of terminals can be live at once,
including on different threads.

**Keys**

- `encode-key term key &key mods utf8 action option-as-alt` returns an octet vector
  for the terminal's current modes (DECCKM, keypad mode, kitty keyboard flags, ...).
- `key` is one of:
  - a character;
  - `:up :down :left :right :home :end :page-up :page-down :insert :delete :backspace :tab :enter :escape :f1`…`:f12`;
  - any `GhosttyKey` name such as `:numpad-5`.
- `mods` is a list of `:shift :ctrl :alt :super`.
- `action` is `:press`, `:repeat` or `:release`.
- `option-as-alt` defaults to `t`, so `:alt` adds an ESC prefix on macOS too.

**Errors**

A failed C call signals `ghostty-error`. Its readers are
`ghostty-error-code` and `ghostty-error-operation`.

A terminal is not thread-safe: use each one from a single thread at a time.

### Raw bindings

`ghostty-vt.ffi` has the raw bindings: `%`-prefixed functions, the C structs
and the enum constants. `(ghostty-vt.ffi:check-abi)` compares each struct's
CFFI size with the size `ghostty_type_json()` reports and warns about any
mismatch. It runs automatically at load time.

### By-value structs

Two C functions take structs by value: `ghostty_terminal_grid_ref`, used for
every cell lookup, and `ghostty_formatter_terminal_new`. CFFI can only make
such calls through cffi-libffi, and each one costs about 9 µs on SBCL/arm64,
which makes reading a cell roughly 20× slower. The build script therefore
compiles a three-function C shim that takes those structs by pointer. The shim
is linked with symbols left unresolved until load time, so it works with
whichever libghostty-vt is already loaded. When the shim is missing, the
bindings fall back to cffi-libffi automatically. The test suite checks that
both paths give the same results.

## License

MIT; see [LICENSE](LICENSE). Ghostty and libghostty-vt are also MIT-licensed
(Copyright (c) 2024 Mitchell Hashimoto, Ghostty contributors).
