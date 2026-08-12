# Docs-only exemption extends to this repo (user decision 2026-08-12)

devMachine's docs-only exemption (see devMachine `CLAUDE.md`) also applies to
dvw: adding or amending files under `docs/**` — nothing else — may be
committed directly to `main` without a PR, provided the push is a clean
fast-forward. Everything else still integrates via PR against protected
`main`.

Context: llmwiki-distiller notes were piling up untracked because the
distiller wrote them without committing. The distiller is being changed
(in aiCodingBaseSetup) to land its docs-only notes on `main` itself; this
decision is what authorizes that for dvw.
