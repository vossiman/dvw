# Throwaway "workspace" for the e2e harness: what dvw-probe expects to find.
# Built from a context the harness assembles outside the checkout (dind.sh
# copies this file and the probe script into $DVW_E2E_ROOT/build), so a run
# never leaves an untracked file in the worktree.
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends tmux git python3 procps ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && useradd -m -u 1000 dev \
    && cp /bin/sleep /usr/local/bin/claude
COPY dvw-probe /usr/local/bin/dvw-probe
RUN chmod 0755 /usr/local/bin/dvw-probe
USER dev
WORKDIR /home/dev
# entrypoint: git repo on a branch in the workspace mount, tmux "work" with a
# window running a process named claude, then stay alive.
COPY --chmod=0755 <<'EOF' /usr/local/bin/ws-entrypoint
#!/bin/sh
set -e
WS="$1"
mkdir -p "$WS" && cd "$WS"
if [ ! -d .git ]; then
  git init -q -b main . && git -c user.email=e@e -c user.name=e commit -q --allow-empty -m init
  git switch -q -c feat/e2e && echo x > dirty.txt
fi
tmux new-session -d -s work -n claude -c "$WS" 'exec claude infinity'
tmux new-window -t work -n shell -c "$WS" 'exec sleep infinity'
exec sleep infinity
EOF
ENTRYPOINT ["/usr/local/bin/ws-entrypoint"]
