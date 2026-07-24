#!/usr/bin/env bash
# Repeatable Codex/tmux scroll-rendering test.
#
# The script records a small, deliberately non-secret diagnostic bundle, runs
# Codex with output long enough to cross the viewport, asks what was visible,
# and appends tmux's internal pane capture to the same log for comparison.

set -uo pipefail

test_line_count=180
test_marker="CODEX_SCROLL_TEST"
scroll_state_root="${XDG_STATE_HOME:-${HOME}/.local/state}/codex-scroll-test"
log_file="${CODEX_SCROLL_TEST_LOG:-${scroll_state_root}/results.log}"
codex_command="${CODEX_SCROLL_TEST_CODEX:-codex}"

usage() {
    cat <<'EOF'
Usage: codex-scroll-test.sh [--log PATH] [--collect-only]

Interactively records the machine/terminal/tmux environment, runs a fixed
long-output Codex test, and appends the result to a log.

Options:
  --log PATH       Append to PATH instead of the default state log.
  --collect-only   Record diagnostics and observations without launching Codex.
  -h, --help       Show this help.

Environment:
  CODEX_SCROLL_TEST_LOG    Alternative log path (overridden by --log).
  CODEX_SCROLL_TEST_CODEX  Alternative Codex executable (useful for testing).
EOF
}

collect_only=0
while (($# > 0)); do
    case "$1" in
        --log)
            if (($# < 2)); then
                printf 'ERROR: --log requires a path\n' >&2
                exit 2
            fi
            log_file=$2
            shift 2
            ;;
        --collect-only)
            collect_only=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            printf 'ERROR: unknown option: %s\n' "$1" >&2
            usage >&2
            exit 2
            ;;
    esac
done

mkdir -p "$(dirname "$log_file")"
touch "$log_file"
chmod 600 "$log_file" 2>/dev/null || true

printf 'Where are you running from? (free text)\n> '
IFS= read -r environment_label
while [[ -z "${environment_label//[[:space:]]/}" ]]; do
    printf 'Please enter a label, for example "home PC / Kitty / DevPod".\n> '
    IFS= read -r environment_label
done

run_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
started_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
test_pane="${TMUX_PANE:-}"
history_before=0

if [[ -n "$test_pane" ]] && command -v tmux >/dev/null 2>&1; then
    history_before="$(tmux display-message -p -t "$test_pane" '#{history_size}' 2>/dev/null || printf '0')"
fi

{
    printf '\n================================================================================\n'
    printf 'CODEX SCROLL TEST %s\n' "$run_id"
    printf 'started_utc: %s\n' "$started_at"
    printf 'environment_label: %s\n' "$environment_label"
    printf 'log_file: %s\n' "$log_file"
    printf '\n[SYSTEM]\n'
    printf 'uname: '
    uname -a 2>&1 || true
    if [[ -r /etc/os-release ]]; then
        printf 'os: '
        awk -F= '/^PRETTY_NAME=/{gsub(/^"|"$/, "", $2); print $2; exit}' /etc/os-release
    fi
    printf 'shell: %s\n' "${SHELL:-<unset>}"
    printf 'locale: %s\n' "${LANG:-<unset>}"
    printf 'TERM: %s\n' "${TERM:-<unset>}"
    printf 'COLORTERM: %s\n' "${COLORTERM:-<unset>}"
    printf 'TERM_PROGRAM: %s\n' "${TERM_PROGRAM:-<unset>}"
    printf 'TERM_PROGRAM_VERSION: %s\n' "${TERM_PROGRAM_VERSION:-<unset>}"
    printf 'TMUX: %s\n' "${TMUX:+set}"
    printf 'TMUX_PANE: %s\n' "${TMUX_PANE:-<unset>}"

    printf '\n[VERSIONS]\n'
    if command -v "$codex_command" >/dev/null 2>&1; then
        "$codex_command" --version 2>&1 || true
    else
        printf 'codex: not found (%s)\n' "$codex_command"
    fi
    if command -v tmux >/dev/null 2>&1; then
        tmux -V 2>&1 || true
    else
        printf 'tmux: not found\n'
    fi

    printf '\n[TMUX CLIENT AND PANE]\n'
    if [[ -n "$test_pane" ]] && command -v tmux >/dev/null 2>&1; then
        tmux display-message -p -t "$test_pane" \
            'client_termname=#{client_termname} client_termtype=#{client_termtype} client_tty=#{client_tty} client_size=#{client_width}x#{client_height}' 2>&1 || true
        tmux display-message -p -t "$test_pane" \
            'pane=#{pane_id} pane_size=#{pane_width}x#{pane_height} alternate=#{alternate_on} mode=#{pane_mode} history=#{history_size} command=#{pane_current_command}' 2>&1 || true

        printf '\n[TMUX RELEVANT OPTIONS]\n'
        tmux show-options -s 2>&1 \
            | awk '/^(default-terminal|escape-time|extended-keys|focus-events|terminal-features|terminal-overrides)/'
        tmux show-options -g 2>&1 \
            | awk '/^(allow-passthrough|history-limit|mouse|set-clipboard|status-interval)/'

        printf '\n[TMUX OUTER TERMINAL CAPABILITIES]\n'
        tmux info 2>&1 \
            | awk '/Terminal [0-9]+:|: (RGB|Sync|Tc|AX|XT|colors|csr|indn|rin|smcup|rmcup):/'

        printf '\n[TMUX WHEEL BINDINGS]\n'
        tmux list-keys -T root 2>&1 | awk '/Wheel(Up|Down)Pane/'
        tmux list-keys -T copy-mode-vi 2>&1 | awk '/Wheel(Up|Down)Pane/'

        printf '\n[TMUX PLUGINS]\n'
        plugin_found=0
        for plugin_dir in "${HOME}/.tmux/plugins"/*; do
            [[ -d "$plugin_dir" ]] || continue
            plugin_found=1
            plugin_name="${plugin_dir##*/}"
            plugin_revision="$(git -C "$plugin_dir" rev-parse --short HEAD 2>/dev/null || printf 'not-git')"
            printf '%s %s\n' "$plugin_name" "$plugin_revision"
        done
        if ((plugin_found == 0)); then
            printf '<none found>\n'
        fi
    else
        printf 'Not running inside tmux; pane capture will be unavailable.\n'
    fi
} >>"$log_file"

printf '\nDiagnostics appended to:\n  %s\n' "$log_file"

if ((collect_only == 0)); then
    if ! command -v "$codex_command" >/dev/null 2>&1; then
        printf 'Codex executable not found: %s\n' "$codex_command" >&2
        collect_only=1
    else
        test_prompt="This is a terminal rendering test. Do not use tools. In your final response, output exactly ${test_line_count} consecutive physical lines. Line N must be the zero-padded three-digit number N, one space, then ${test_marker}. Start with 001 and end with ${test_line_count}. Do not use a code fence, table, ranges, commentary, headings, blank lines, or omissions."

        printf '\nThe script will now launch Codex in inline mode with a fixed %d-line prompt.\n' "$test_line_count"
        printf 'Watch until output passes the top of the screen. If it looks wrong, scroll\n'
        printf 'up and back down once and note whether that repairs it. Then exit Codex with /quit.\n'
        printf 'Press Enter to start (Ctrl+C to cancel).\n'
        IFS= read -r _

        {
            printf '\n[TEST INVOCATION]\n'
            printf 'command: %s --no-alt-screen <fixed prompt>\n' "$codex_command"
            printf 'expected_lines: %d\n' "$test_line_count"
            printf 'marker: %s\n' "$test_marker"
        } >>"$log_file"

        "$codex_command" --no-alt-screen "$test_prompt"
        codex_status=$?
        printf 'codex_exit_status: %d\n' "$codex_status" >>"$log_file"
    fi
fi

printf '\nDid the output render incorrectly? [yes/no/unsure]\n> '
IFS= read -r rendering_result
printf 'Did scrolling up and back down repair it? [yes/no/not-tested]\n> '
IFS= read -r redraw_result
printf 'Any notes? (one line, free text; Enter for none)\n> '
IFS= read -r observation_notes

{
    printf '\n[OBSERVATION]\n'
    printf 'rendering_incorrect: %s\n' "${rendering_result:-unspecified}"
    printf 'scroll_redraw_repaired: %s\n' "${redraw_result:-unspecified}"
    printf 'notes: %s\n' "${observation_notes:-<none>}"
} >>"$log_file"

if [[ -n "$test_pane" ]] && command -v tmux >/dev/null 2>&1; then
    history_after="$(tmux display-message -p -t "$test_pane" '#{history_size}' 2>/dev/null || printf '0')"
    capture_start=0
    if [[ "$history_before" =~ ^[0-9]+$ && "$history_after" =~ ^[0-9]+$ ]] \
        && ((history_after > history_before)); then
        capture_start="-$((history_after - history_before + 5))"
    fi

    capture_file="$(mktemp)"
    trap 'rm -f "$capture_file"' EXIT
    if tmux capture-pane -p -t "$test_pane" -S "$capture_start" >"$capture_file" 2>/dev/null; then
        integrity_summary="$(awk -v expected="$test_line_count" -v marker="$test_marker" '
            {
                pattern = "[0-9][0-9][0-9] " marker
                if (match($0, pattern)) {
                    number = substr($0, RSTART, 3) + 0
                    if (number >= 1 && number <= expected) {
                        occurrences++
                        seen[number]++
                    }
                }
            }
            END {
                unique = 0
                duplicates = 0
                missing = ""
                for (i = 1; i <= expected; i++) {
                    if (seen[i] > 0) unique++
                    if (seen[i] > 1) duplicates += seen[i] - 1
                    if (seen[i] == 0) missing = missing (missing == "" ? "" : ",") i
                }
                if (missing == "") missing = "none"
                printf "occurrences=%d unique=%d duplicates=%d missing=%s", occurrences, unique, duplicates, missing
            }
        ' "$capture_file")"

        {
            printf '\n[TMUX CAPTURE AFTER TEST]\n'
            printf 'history_before: %s\n' "$history_before"
            printf 'history_after: %s\n' "$history_after"
            printf 'capture_start: %s\n' "$capture_start"
            printf 'integrity: %s\n' "$integrity_summary"
            printf '%s\n' '--- pane capture begin ---'
            cat "$capture_file"
            printf '%s\n' '--- pane capture end ---'
        } >>"$log_file"
    else
        printf '\n[TMUX CAPTURE AFTER TEST]\ncapture_failed: true\n' >>"$log_file"
    fi
fi

finished_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
{
    printf 'finished_utc: %s\n' "$finished_at"
    printf 'END CODEX SCROLL TEST %s\n' "$run_id"
    printf '================================================================================\n'
} >>"$log_file"

printf '\nTest recorded. Log:\n  %s\n' "$log_file"

