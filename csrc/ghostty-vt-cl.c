/*
 * ghostty-vt-cl.c -- pointer-taking wrappers for libghostty-vt functions
 * that take structs by value.
 *
 * CFFI can only pass structs by value through cffi-libffi, whose per-call
 * overhead (~9us on SBCL/arm64) dominates cell access. These wrappers let
 * the Lisp side pass a pointer to a reused buffer instead. The library is
 * linked with undefined symbols resolved at load time, so it works with
 * whichever libghostty-vt has already been loaded into the process.
 */
#include <ghostty/vt.h>

GHOSTTY_API GhosttyResult
cl_ghostty_vt_terminal_grid_ref(GhosttyTerminal terminal,
                                const GhosttyPoint *point,
                                GhosttyGridRef *out_ref) {
  return ghostty_terminal_grid_ref(terminal, *point, out_ref);
}

GHOSTTY_API GhosttyResult
cl_ghostty_vt_formatter_terminal_new(const GhosttyAllocator *allocator,
                                     GhosttyFormatter *formatter,
                                     GhosttyTerminal terminal,
                                     const GhosttyFormatterTerminalOptions *options) {
  return ghostty_formatter_terminal_new(allocator, formatter, terminal, *options);
}

GHOSTTY_API unsigned int cl_ghostty_vt_shim_version(void) { return 1; }
