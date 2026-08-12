# `gh pr merge` picked the wrong repo because of cwd

Running `gh pr merge 37 --merge --delete-branch` from `/workspaces/devmachine`
(the parent devMachine checkout) instead of `/workspaces/devmachine/devpod/dvw`
silently targeted the **devMachine** repo's PR #37 (already merged) instead of
the intended **dvw** submodule PR #37. `gh` resolves the target repo from the
current working directory's git remote, not from context or prior
conversation, and there was no error — just a plausible-looking "already
merged" message — so the mistake wasn't obvious from the output alone.

Lesson: in this nested devMachine/submodule workspace, always `cd` into the
specific submodule checkout (or pass `--repo owner/name`) before any `gh pr`
command, and double-check the printed repo URL in the result, especially when
PR numbers could coincidentally collide across the parent repo and its
submodules.
