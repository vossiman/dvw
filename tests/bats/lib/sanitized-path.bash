# Shared bats helper: a PATH from which chosen tools are genuinely ABSENT.
#
# Why this exists
# ---------------
# dvw probes the environment with `command -v <tool>` and branches on the
# result (clipboard tools in lib/push.sh, fzf vs the numbered picker, ...).
# Tests that want the tool-absent branch cannot fake absence with a stub —
# `command -v` finds the stub and takes the tool-PRESENT branch. So absence
# has to be real, which means the tool must not be on PATH at all.
#
# Narrowing PATH to "/usr/bin:/bin" does NOT achieve that: those directories
# are exactly where the real tools live. Two files carried that mistake, and
# both were wrong on any developer desktop while staying green on headless CI
# where the tools genuinely are missing (found 2026-08-20):
#
#   push-cmd.bats     assumed no clipboard tool. Real `xclip -selection
#                     clipboard` forks and stays resident to own the X
#                     selection, so the pipe write never saw EOF and the whole
#                     suite WEDGED indefinitely.
#   push-target.bats  `export PATH="/usr/bin:/bin"  # no fzf`. With fzf
#                     installed the fzf branch ran instead of the numbered
#                     picker; two tests failed on main.
#
# What it does
# ------------
# Builds a mirror of /usr/bin and /bin as symlinks, omitting the named tools,
# so everything else on the system still resolves normally. Call it once per
# file from setup_file() and put it after the per-test stub dir on PATH:
#
#   setup_file() {
#     load "lib/sanitized-path.bash"
#     sanitized_bin_init "$BATS_FILE_TMPDIR/sanitized-bin" xclip wl-copy
#   }
#   setup() { export PATH="$STUB_BIN:$SANITIZED_BIN"; }
#
# A test that wants one of the hidden tools to be PRESENT drops a stub into
# its own $STUB_BIN, which precedes $SANITIZED_BIN — so per-test opt-in still
# works, it is just no longer the accidental default.
#
# Pair it with a guard test asserting the tools really are unreachable;
# otherwise a future PATH edit silently re-enables the host's real binaries.

# sanitized_bin_init <dir> <tool>...
# Exports SANITIZED_BIN=<dir>.
sanitized_bin_init() {
  local dir="$1"; shift
  local hide=" $* "
  mkdir -p "$dir"
  local d f b
  for d in /usr/bin /bin; do
    [ -d "$d" ] || continue
    for f in "$d"/*; do
      b=${f##*/}
      case "$hide" in *" $b "*) continue ;; esac
      # Executable regular files only. These dirs also hold directories
      # (/usr/bin/X11, a symlink back to /usr/bin) and dangling symlinks
      # (dmtracedump). -f follows symlinks, so real symlinked binaries are
      # kept while both of those are skipped. Using `ln -f` rather than an
      # [ -e ] guard because -e is false for a dangling link whose NAME is
      # nonetheless taken, which makes ln fail.
      if [ -f "$f" ] && [ -x "$f" ]; then
        ln -sf "$f" "$dir/$b"
      fi
    done
  done
  export SANITIZED_BIN="$dir"
}
