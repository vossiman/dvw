# jumpi: the dvw bastion

"jumpi" is the name for a small always-on box — typically a Raspberry Pi —
that you Termius into from your phone. It's the entry point when you're away
from a laptop: you SSH from Android into jumpi, and jumpi runs the full `dvw`
client so you can reach `vossisrv` and your workspaces from there.

The phone itself never runs dvw and never holds a `vossisrv` key. It only
needs an SSH client (Termius) and a key for jumpi. Everything past that —
reaching `vossisrv`, talking to the catalog service, attaching to tmux
sessions — happens on jumpi, using jumpi's own keys.

## Setup

jumpi just needs a clone of the public `dvw` repo and one script — no token,
since the repo is public:

```bash
git clone https://github.com/vossiman/dvw && cd dvw && bash install-bastion.sh
```

`install-bastion.sh`:

1. Makes sure the `devpod` CLI is present (needed for the `devpod ssh
   --stdio` `ProxyCommand` some dvw connect flows use), installing it from
   the latest GitHub release if missing.
2. Delegates to `dvw-install.sh` (the same idempotent client installer used
   on any dvw workstation) to install/refresh the `dvw` client itself.
3. Prints a reachability report: whether jumpi can SSH to `vossisrv`, and
   whether a `devpod` context is configured.

It's idempotent — re-run it anytime, e.g. after `dvw update` or to check
status:

```bash
bash install-bastion.sh --check   # report only, makes no changes
```

Once it reports OK, add a Termius host called `jumpi` pointing at this box,
using your normal SSH key. From there you have the full `dvw` client
available: `dvw`, `dvw doctor`, `dvw attach`, etc.

## Using `dvw attach` from your phone

`dvw attach` jumps straight to the tmux window most recently flagged
`@waiting` (by agent-notify) — the fastest way to check on a coding agent
that just pinged you. Zero waiting windows falls through to the normal dvw
menu; exactly one connects you straight in; more than one gives you a
picker, newest first.

## Optional: zero-keystroke attach

If you want a Termius host that connects and drops you straight into the
waiting window without typing anything, you can add a **second** SSH keypair
on jumpi that's restricted to running only `dvw attach`. This is a manual,
optional setup — not automated by `install-bastion.sh`.

1. Generate a second keypair (on jumpi, or import one you generate
   elsewhere) — do **not** reuse your normal jumpi key for this.
2. In jumpi's `~/.ssh/authorized_keys`, add the new public key on its own
   line, restricted with a forced command:

   ```
   command="dvw attach",no-port-forwarding,no-X11-forwarding <pubkey>
   ```

   The `command=` restriction means any SSH session authenticated with this
   key runs `dvw attach` and nothing else — no shell, no port forwarding, no
   X11 forwarding.
3. In Termius, add a second host — e.g. "jumpi ⏸" — using this restricted
   key. Opening it connects and immediately attaches to whatever's waiting,
   no menu, no typing.

Keep your normal "jumpi" host (unrestricted key) for everything else: `dvw
doctor`, browsing workspaces, running `dvw update`, etc.

## Staying current

To keep jumpi's `dvw` client up to date, run:

```bash
dvw update
```

This is the same update path used on any dvw workstation: it fast-forwards
the checkout to `origin/main`. Re-running `install-bastion.sh` afterward is
safe (idempotent) if you want to also refresh `devpod` or re-check
reachability.
