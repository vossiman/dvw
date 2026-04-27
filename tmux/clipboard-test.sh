#!/bin/bash
# clipboard-test.sh — Interactive clipboard round-trip tester
# Tests multiple clipboard pathways and asks user to verify each one.
# Usage: bash clipboard-test.sh

set -euo pipefail

# ─── Helpers ──────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

info()  { printf "${CYAN}[INFO]${RESET}  %s\n" "$1"; }
ok()    { printf "${GREEN}[PASS]${RESET}  %s\n" "$1"; }
bad()   { printf "${RED}[FAIL]${RESET}  %s\n" "$1"; }
warn()  { printf "${YELLOW}[WARN]${RESET}  %s\n" "$1"; }
skip()  { printf "${DIM}[SKIP]${RESET}  %s\n" "$1"; }

ask_verify() {
    local method="$1"
    local expected="$2"

    printf "\n"
    printf "  ${BOLD}Test: %s${RESET}\n" "$method"
    printf "  Expected string: ${GREEN}%s${RESET}\n" "$expected"
    printf "\n"
    printf "  Paste from your system clipboard now (Ctrl+V / Ctrl+Shift+V / right-click),\n"
    printf "  then press Enter. Or just press Enter to skip.\n"
    printf "  > "

    local pasted=""
    read -r pasted

    if [[ -z "$pasted" ]]; then
        skip "$method — skipped by user"
        return 2
    elif [[ "$pasted" == "$expected" ]]; then
        ok "$method — clipboard round-trip works!"
        return 0
    else
        bad "$method — got '${pasted}' instead of '${expected}'"
        return 1
    fi
}

generate_token() {
    local method="$1"
    echo "CB_${method}_$(date +%s)_$$"
}

# ─── Tests ────────────────────────────────────────────────────────────────────

test_osc52_direct() {
    local token
    token=$(generate_token "OSC52")
    local b64
    b64=$(echo -n "$token" | base64)

    info "Sending OSC 52 direct clipboard write..."
    printf '\e]52;c;%s\a' "$b64" > /dev/tty 2>/dev/null

    ask_verify "OSC 52 Direct" "$token"
}

test_dcs_passthrough() {
    if [[ -z "${TMUX:-}" ]]; then
        skip "DCS Passthrough — not inside tmux"
        return 2
    fi

    local token
    token=$(generate_token "DCS")
    local b64
    b64=$(echo -n "$token" | base64)

    info "Sending DCS-wrapped OSC 52 passthrough..."
    printf '\ePtmux;\e\e]52;c;%s\a\e\\' "$b64" > /dev/tty 2>/dev/null

    ask_verify "DCS Passthrough (tmux → outer terminal)" "$token"
}

test_xclip() {
    if ! command -v xclip &>/dev/null; then
        skip "xclip — not installed"
        return 2
    fi

    if [[ -z "${DISPLAY:-}" ]]; then
        skip "xclip — no DISPLAY set"
        return 2
    fi

    local token
    token=$(generate_token "XCLIP")

    info "Writing to clipboard via xclip..."
    if echo -n "$token" | xclip -selection clipboard 2>/dev/null; then
        ask_verify "xclip" "$token"
    else
        bad "xclip — write failed (X11 connection issue?)"
        return 1
    fi
}

test_xsel() {
    if ! command -v xsel &>/dev/null; then
        skip "xsel — not installed"
        return 2
    fi

    if [[ -z "${DISPLAY:-}" ]]; then
        skip "xsel — no DISPLAY set"
        return 2
    fi

    local token
    token=$(generate_token "XSEL")

    info "Writing to clipboard via xsel..."
    if echo -n "$token" | xsel --clipboard --input 2>/dev/null; then
        ask_verify "xsel" "$token"
    else
        bad "xsel — write failed"
        return 1
    fi
}

test_wl_copy() {
    if ! command -v wl-copy &>/dev/null; then
        skip "wl-copy — not installed"
        return 2
    fi

    if [[ -z "${WAYLAND_DISPLAY:-}" ]]; then
        skip "wl-copy — no WAYLAND_DISPLAY set"
        return 2
    fi

    local token
    token=$(generate_token "WLCOPY")

    info "Writing to clipboard via wl-copy..."
    if echo -n "$token" | wl-copy 2>/dev/null; then
        ask_verify "wl-copy (Wayland)" "$token"
    else
        bad "wl-copy — write failed"
        return 1
    fi
}

test_tmux_buffer() {
    if [[ -z "${TMUX:-}" ]]; then
        skip "tmux buffer — not inside tmux"
        return 2
    fi

    local token
    token=$(generate_token "TBUF")

    info "Loading into tmux paste buffer..."
    echo -n "$token" | tmux load-buffer -

    printf "\n"
    printf "  ${BOLD}Test: tmux buffer${RESET}\n"
    printf "  Expected string: ${GREEN}%s${RESET}\n" "$token"
    printf "\n"
    printf "  Use tmux paste (prefix + ] or right-click if bound) to paste,\n"
    printf "  then press Enter. Or just press Enter to skip.\n"
    printf "  > "

    local pasted=""
    read -r pasted

    if [[ -z "$pasted" ]]; then
        skip "tmux buffer — skipped by user"
        return 2
    elif [[ "$pasted" == "$token" ]]; then
        ok "tmux buffer — works!"
        return 0
    else
        bad "tmux buffer — got '${pasted}' instead of '${token}'"
        return 1
    fi
}

test_tmux_yank_script() {
    local script="$HOME/.local/bin/tmux-yank.sh"

    if [[ ! -x "$script" ]]; then
        skip "tmux-yank.sh — not found or not executable at $script"
        return 2
    fi

    if [[ -z "${TMUX:-}" ]]; then
        skip "tmux-yank.sh — not inside tmux"
        return 2
    fi

    local token
    token=$(generate_token "YANK")

    info "Writing via tmux-yank.sh (the copy-pipe script)..."
    echo -n "$token" | "$script"

    ask_verify "tmux-yank.sh (DCS passthrough + tmux buffer)" "$token"
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    printf "\n"
    printf "${BOLD}═══ CLIPBOARD ROUND-TRIP TESTER ═══════════════════════${RESET}\n"
    printf "\n"
    printf "  This script writes unique strings to your clipboard via\n"
    printf "  different methods and asks you to paste them back to verify.\n"
    printf "\n"
    printf "  Environment: ${CYAN}%s${RESET}\n" "$(hostname)"
    printf "  Inside tmux: %s\n" "${TMUX:+YES}"
    printf "  Over SSH:    %s\n" "${SSH_CONNECTION:+YES}"
    printf "\n"
    printf "${BOLD}═══════════════════════════════════════════════════════${RESET}\n"

    local pass=0 fail=0 skipped=0 total=0

    run_test() {
        local result=0
        "$1" || result=$?
        ((total++))
        case $result in
            0) ((pass++)) ;;
            1) ((fail++)) ;;
            2) ((skipped++)) ;;
        esac
    }

    run_test test_osc52_direct
    run_test test_dcs_passthrough
    run_test test_xclip
    run_test test_xsel
    run_test test_wl_copy
    run_test test_tmux_buffer
    run_test test_tmux_yank_script

    printf "\n"
    printf "${BOLD}═══ RESULTS ═══════════════════════════════════════════${RESET}\n"
    printf "\n"
    printf "  ${GREEN}Passed:${RESET}  %d\n" "$pass"
    printf "  ${RED}Failed:${RESET}  %d\n" "$fail"
    printf "  ${DIM}Skipped:${RESET} %d\n" "$skipped"
    printf "  Total:   %d\n" "$total"
    printf "\n"

    if [[ $fail -gt 0 ]]; then
        printf "  ${YELLOW}Recommendation:${RESET} Run ${BOLD}bash tmux-diag.sh${RESET} for detailed\n"
        printf "  environment and config analysis.\n"
    elif [[ $pass -gt 0 ]]; then
        printf "  ${GREEN}At least one clipboard pathway works!${RESET}\n"
    else
        printf "  ${YELLOW}All tests skipped — try running inside different environments.${RESET}\n"
    fi

    printf "\n"
    printf "${BOLD}═══════════════════════════════════════════════════════${RESET}\n"
    printf "\n"
}

main "$@"
