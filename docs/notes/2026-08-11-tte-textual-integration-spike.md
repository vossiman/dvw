# terminaltexteffects (TTE) + Textual integration spike — findings

Context: brainstorming session exploring whether `terminaltexteffects` (the
library behind the `ttfx` CLI) can drive motion in the dvw TUI (Textual).
Ideation/spike only — no code landed in this session; captured here so the
verified facts aren't lost if the design work continues later.

## Verified facts (from a throwaway `/tmp` scratchpad venv, not the project)

- TTE effect classes (e.g. `terminaltexteffects.effects.effect_decrypt.Decrypt`)
  are plain Python iterators yielding ANSI strings. `terminal_output()` — the
  part that grabs the real terminal screen — is entirely optional; you never
  have to call it. This means TTE can run **in-process inside Textual**,
  producing frames you feed into a widget via `Text.from_ansi(frame)`, with no
  subprocess and no fight over screen ownership. The earlier assumption that
  `ttfx` (the CLI) can't coexist with a Textual app is correct, but it doesn't
  apply to using the TTE *library* directly.
- Effects size to an explicit canvas rather than the terminal, via
  `effect.terminal_config`: set `ignore_terminal_dimensions = True` and
  `canvas_width` / `canvas_height` to the target widget size.
- Default playback is far too slow for a tool launched repeatedly: a
  `Decrypt` effect on a ~35-char string produced **582–670 frames at default
  60fps (~10-11s)**, and the frame count is **non-deterministic run to run**
  (582/584/670 observed across three runs of the identical input).
- Fix: set `frame_rate = 0` on `terminal_config` to discard TTE's own timing,
  materialize all frames up front (cheap — ~22ms for ~584 frames), then
  *stride* the frame list down to a fixed count that hits a wall-clock budget
  you own (e.g. 400ms at 30fps → 14 kept frames). Always append the true
  final frame explicitly, since striding can skip it. This makes the frame
  count's non-determinism irrelevant — playback duration is stable regardless
  of how many raw frames TTE produced.
- 37 effects ship with the library; a curated subset that reads well at
  banner/widget size (not full-terminal size) was hand-picked during the
  spike: `decrypt, matrix, beams, slide, wipe, expand, binarypath, laseretch,
  scattered, print, swarm, blackhole, burn, spotlights, rain`.

## Other agents' TUI stacks (for context, verified by binary/repo inspection)

- Claude Code: Node/TS + **Ink** (React-for-terminals, Yoga flexbox) —
  confirmed via strings in the shipped `claude` binary (`ink-text`,
  `ink-box`, `yoga`, `reconciler` all present).
- opencode: TypeScript on Bun + **OpenTUI** (`@opentui/core` + `solid-js`) —
  confirmed via `packages/tui/package.json`; the repo's Go/Bubble Tea TUI was
  dropped (repo language breakdown shows zero Go now).
- Neither of these architectures suits piping TTE's frame iterators in the
  way Textual does — Ink/OpenTUI don't have TTE as an in-language library
  option, so the "TTE only works as a CLI filter, incompatible with a
  full-screen app" problem would actually apply to them, unlike to Textual.
