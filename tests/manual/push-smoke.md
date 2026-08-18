# dvw push — manual smoke test

The bats suite stubs ssh/scp; this is the real-transport check (first run
2026-08-18 during the design spike, against workspace `devmachine`).

From any dvw client attached to a running workspace `<ws>` (second shell):

1. `echo hi > /tmp/dvw-push-test.txt && dvw push /tmp/dvw-push-test.txt`
   — expect an OK line and final line `/tmp/dvw-push-test.txt`.
2. In the workspace: `cat /tmp/dvw-push-test.txt` → `hi`.
3. Phone flow (jumpi): paste an image from Termius at a jumpi prompt, run
   bare `dvw push`, confirm the printed `/tmp/<uuid>.<ext>` opens inside
   the workspace (e.g. hand it to an agent or `file` it).
4. `dvw push --to <stopped-ws> /tmp/dvw-push-test.txt` → must refuse with
   "not running", and `dvw status` must still show the workspace stopped
   (nothing auto-booted).
5. Desktop only: copy an image to the clipboard, `dvw push --clipboard`,
   verify the pushed png renders and the path landed on the local clipboard.
