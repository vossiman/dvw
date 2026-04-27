#!/bin/bash
# tmux-diag.sh — Comprehensive tmux terminal diagnostics
# Run in any environment to detect clipboard, escape sequence, and config issues.
# Usage: bash tmux-diag.sh

set -euo pipefail

# ─── Output helpers ───────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
RESET='\033[0m'

pass()    { printf "${GREEN}PASS${RESET}";    }
fail()    { printf "${RED}FAIL${RESET}";       }
warn()    { printf "${YELLOW}WARN${RESET}";    }
partial() { printf "${YELLOW}PARTIAL${RESET}"; }
skip()    { printf "${CYAN}SKIP${RESET}";      }

field() {
    # field TAG LABEL VALUE
    printf "  [%-4s] %-22s %s\n" "$1" "$2" "$3"
}

header() {
    printf "\n${BOLD}%s${RESET}\n" "$1"
}

divider() {
    printf '%.0s═' {1..55}
    printf '\n'
}

# Summary collector
declare -a SUMMARY_PASS=()
declare -a SUMMARY_WARN=()
declare -a SUMMARY_FAIL=()

summary_pass() { SUMMARY_PASS+=("$1"); }
summary_warn() { SUMMARY_WARN+=("$1"); }
summary_fail() { SUMMARY_FAIL+=("$1"); }

# ─── Environment classification ──────────────────────────────────────────────

detect_env_type() {
    local label=""
    if [[ -n "${TMUX:-}" ]]; then
        label="TMUX"
    fi
    # Use SSH_CONNECTION as the reliable SSH indicator (tmux update-environment refreshes it).
    # SSH_TTY inside tmux is often stale — only trust it outside tmux.
    local ssh_detected="no"
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        ssh_detected="yes"
    elif [[ -n "${SSH_TTY:-}" && -z "${TMUX:-}" ]]; then
        ssh_detected="yes"
    fi
    if [[ "$ssh_detected" == "yes" ]]; then
        if [[ -n "$label" ]]; then
            label="SSH+TMUX"
        else
            label="SSH"
        fi
    fi
    if [[ -z "$label" ]]; then
        label="LOCAL"
    fi
    echo "$label"
}

# ─── Read terminal response with timeout ─────────────────────────────────────

# Send an escape sequence and read back the terminal's response.
# Uses raw terminal I/O with a configurable timeout.
# Returns 0 if a response was received, 1 if timeout.
read_terminal_response() {
    local sequence="$1"
    local timeout="${2:-0.5}"
    local response=""

    # Save terminal state and switch to raw mode
    local old_settings
    old_settings=$(stty -g 2>/dev/null) || return 1
    stty raw -echo min 0 time "$(awk "BEGIN{printf \"%d\", $timeout * 10}")" 2>/dev/null || return 1

    # Send the query
    printf '%s' "$sequence" > /dev/tty

    # Read response character by character
    local char
    while true; do
        char=$(dd bs=1 count=1 2>/dev/null < /dev/tty) || break
        if [[ -z "$char" ]]; then
            break
        fi
        response+="$char"
        # Stop at common terminators: BEL (\a = 0x07) or ST (\e\\)
        if [[ "$char" == $'\a' ]] || [[ "$response" == *$'\e\\' ]]; then
            break
        fi
    done

    # Restore terminal
    stty "$old_settings" 2>/dev/null

    if [[ -n "$response" ]]; then
        echo "$response"
        return 0
    fi
    return 1
}

# ─── Section 1: Environment Detection ────────────────────────────────────────

section_environment() {
    header "ENVIRONMENT"

    field "ENV" "TERM .............." "${TERM:-<unset>}"
    field "ENV" "COLORTERM ........." "${COLORTERM:-<unset>}"
    field "ENV" "TERM_PROGRAM ......" "${TERM_PROGRAM:-<unset>}"
    field "ENV" "TERM_PROGRAM_VER .." "${TERM_PROGRAM_VERSION:-<unset>}"

    # tmux detection
    if [[ -n "${TMUX:-}" ]]; then
        local tmux_ver
        tmux_ver=$(tmux -V 2>/dev/null | head -1 || echo "unknown")
        field "ENV" "Inside tmux? ......" "YES ($tmux_ver)"
    else
        field "ENV" "Inside tmux? ......" "NO"
    fi

    # SSH detection — prefer SSH_CONNECTION (updated by tmux) over SSH_TTY (may be stale)
    local is_ssh="no"
    if [[ -n "${SSH_CONNECTION:-}" ]]; then
        is_ssh="yes"
        field "ENV" "Over SSH? ........." "YES (${SSH_CONNECTION})"
    elif [[ -n "${SSH_TTY:-}" && -z "${TMUX:-}" ]]; then
        # SSH_TTY without tmux — trust it
        is_ssh="yes"
        field "ENV" "Over SSH? ........." "YES (TTY: ${SSH_TTY})"
    elif [[ -n "${SSH_TTY:-}" ]]; then
        # SSH_TTY inside tmux — likely stale (not in update-environment)
        field "ENV" "Over SSH? ........." "MAYBE (SSH_TTY=${SSH_TTY} but may be stale in tmux)"
    else
        field "ENV" "Over SSH? ........." "NO"
    fi

    # Nesting depth
    local depth=0
    [[ -n "${TMUX:-}" ]] && depth=$((depth + 1))
    [[ "$is_ssh" == "yes" ]] && depth=$((depth + 1))
    field "ENV" "Nesting depth ....." "$depth"

    # Locale
    local lang="${LANG:-<unset>}"
    field "ENV" "LANG .............." "$lang"

    # ble.sh
    if [[ -n "${BLE_VERSION:-}" ]]; then
        field "ENV" "ble.sh ............" "YES (v${BLE_VERSION})"
    elif type -t ble &>/dev/null; then
        field "ENV" "ble.sh ............" "YES (function found)"
    else
        field "ENV" "ble.sh ............" "NO"
    fi

    # Clipboard tools
    local clip_tools=""
    command -v xclip &>/dev/null && clip_tools+="xclip "
    command -v xsel &>/dev/null && clip_tools+="xsel "
    command -v wl-copy &>/dev/null && clip_tools+="wl-copy "
    command -v pbcopy &>/dev/null && clip_tools+="pbcopy "
    field "ENV" "Clipboard tools ..." "${clip_tools:-<none>}"

    # DISPLAY / WAYLAND_DISPLAY
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        field "ENV" "Display server ...." "Wayland (${WAYLAND_DISPLAY})"
    elif [[ -n "${DISPLAY:-}" ]]; then
        field "ENV" "Display server ...." "X11 (${DISPLAY})"
    else
        field "ENV" "Display server ...." "<none>"
    fi
}

# ─── Section 2: OSC 52 Clipboard Test ────────────────────────────────────────

section_clipboard() {
    header "OSC 52 CLIPBOARD"

    local test_string="TMUX_DIAG_$(date +%s)"
    local test_b64
    test_b64=$(echo -n "$test_string" | base64)

    # Determine the correct TTY to talk to
    local tty_target="/dev/tty"

    # Test 1: OSC 52 write (direct)
    # We can't truly verify a write succeeded without reading back,
    # but we can at least send it and check if the terminal errors.
    printf '\e]52;c;%s\a' "$test_b64" > "$tty_target" 2>/dev/null
    local write_status=$?

    # Test 2: OSC 52 read-back
    local read_response=""
    local read_status="FAIL"
    read_response=$(read_terminal_response $'\e]52;c;?\a' 1.0 2>/dev/null) || true

    if [[ -n "$read_response" ]]; then
        # Check if response contains our test string in base64
        if [[ "$read_response" == *"$test_b64"* ]]; then
            read_status="PASS"
        else
            # Got a response but not our string — might be stale clipboard
            read_status="RESPONSE"
        fi
    fi

    # Test 3: DCS passthrough (only inside tmux)
    local dcs_status="SKIP"
    if [[ -n "${TMUX:-}" ]]; then
        local dcs_test="TMUX_DCS_$(date +%s)"
        local dcs_b64
        dcs_b64=$(echo -n "$dcs_test" | base64)
        printf '\ePtmux;\e\e]52;c;%s\a\e\\' "$dcs_b64" > "$tty_target" 2>/dev/null

        # Try to read back
        local dcs_response=""
        dcs_response=$(read_terminal_response $'\e]52;c;?\a' 1.0 2>/dev/null) || true

        if [[ -n "$dcs_response" ]]; then
            if [[ "$dcs_response" == *"$dcs_b64"* ]]; then
                dcs_status="PASS"
            else
                dcs_status="RESPONSE"
            fi
        else
            # Can't read back, but write might have worked — mark as UNKNOWN
            dcs_status="UNKNOWN"
        fi
    fi

    # Report results
    if [[ $write_status -eq 0 ]]; then
        if [[ "$read_status" == "PASS" ]]; then
            field "CLIP" "OSC 52 write ......" "$(pass) (verified via read-back)"
            summary_pass "OSC 52 clipboard write+read works"
        elif [[ "$read_status" == "RESPONSE" ]]; then
            field "CLIP" "OSC 52 write ......" "$(pass) (sent OK, read-back got different data)"
            field "CLIP" "OSC 52 read ......." "$(partial) (response received, content mismatch)"
            summary_warn "OSC 52 read-back returned unexpected content"
        else
            field "CLIP" "OSC 52 write ......" "$(warn) (sent, but cannot verify — no read-back)"
            field "CLIP" "OSC 52 read ......." "$(fail) (no response within timeout)"
            summary_warn "OSC 52 read-back not supported — write-only clipboard"
        fi
    else
        field "CLIP" "OSC 52 write ......" "$(fail) (write error)"
        field "CLIP" "OSC 52 read ......." "$(skip)"
        summary_fail "OSC 52 clipboard write failed"
    fi

    # DCS passthrough result
    case "$dcs_status" in
        PASS)
            field "CLIP" "DCS passthrough ..." "$(pass) (verified via read-back)"
            summary_pass "DCS passthrough working — nested clipboard should work"
            ;;
        RESPONSE)
            field "CLIP" "DCS passthrough ..." "$(partial) (response received, content mismatch)"
            summary_warn "DCS passthrough: response received but content unexpected"
            ;;
        UNKNOWN)
            field "CLIP" "DCS passthrough ..." "$(warn) (sent, cannot verify — read-back unavailable)"
            summary_warn "DCS passthrough sent but could not verify"
            ;;
        SKIP)
            field "CLIP" "DCS passthrough ..." "$(skip) (not inside tmux)"
            ;;
        *)
            field "CLIP" "DCS passthrough ..." "$(fail)"
            summary_fail "DCS passthrough failed"
            ;;
    esac
}

# ─── Section 3: OSC Color Query Test ─────────────────────────────────────────

section_color_queries() {
    header "OSC COLOR QUERIES"

    # OSC 10 — foreground color
    local osc10_response=""
    osc10_response=$(read_terminal_response $'\e]10;?\a' 0.5 2>/dev/null) || true

    if [[ -n "$osc10_response" ]]; then
        # Sanitize for display (remove control chars)
        local osc10_display
        osc10_display=$(echo "$osc10_response" | tr -cd '[:print:]' | head -c 60)
        field "OSC" "Color query 10 ...." "$(pass) (response: ${osc10_display})"
        summary_pass "OSC 10 (foreground color query) supported"
    else
        field "OSC" "Color query 10 ...." "$(warn) (no response — terminal may not support it)"
        summary_warn "OSC 10 not supported or timed out"
    fi

    # OSC 11 — background color
    local osc11_response=""
    osc11_response=$(read_terminal_response $'\e]11;?\a' 0.5 2>/dev/null) || true

    if [[ -n "$osc11_response" ]]; then
        local osc11_display
        osc11_display=$(echo "$osc11_response" | tr -cd '[:print:]' | head -c 60)
        field "OSC" "Color query 11 ...." "$(pass) (response: ${osc11_display})"
        summary_pass "OSC 11 (background color query) supported"
    else
        field "OSC" "Color query 11 ...." "$(warn) (no response — terminal may not support it)"
        summary_warn "OSC 11 not supported or timed out"
    fi

    # Inside tmux: check if color queries leak through passthrough
    if [[ -n "${TMUX:-}" ]]; then
        local passthrough
        passthrough=$(tmux show -gv allow-passthrough 2>/dev/null || echo "unknown")
        if [[ "$passthrough" == "on" ]]; then
            field "OSC" "Passthrough risk .." "$(warn) allow-passthrough=on — OSC queries may leak to outer terminal"
            summary_warn "allow-passthrough=on — ble.sh/starship OSC queries may leak and cause garbled output"
        else
            field "OSC" "Passthrough risk .." "$(pass) allow-passthrough=${passthrough}"
        fi
    fi
}

# ─── Section 4: DCS Passthrough Test ─────────────────────────────────────────

section_dcs_passthrough() {
    header "DCS PASSTHROUGH"

    if [[ -z "${TMUX:-}" ]]; then
        field "DCS" "Status ............" "$(skip) (not inside tmux — DCS passthrough N/A)"
        return
    fi

    local passthrough_val
    passthrough_val=$(tmux show -gv allow-passthrough 2>/dev/null || echo "unknown")
    field "DCS" "allow-passthrough .." "$passthrough_val"

    if [[ "$passthrough_val" != "on" ]]; then
        field "DCS" "Status ............" "$(fail) allow-passthrough is not 'on' — DCS won't work"
        summary_fail "DCS passthrough disabled (allow-passthrough=${passthrough_val})"
        return
    fi

    # Send a DCS-wrapped DA (Device Attributes) query as a simple probe
    # This tests whether the outer terminal receives and responds to
    # sequences tunneled through tmux.
    local dcs_probe_response=""
    # Use OSC 52 query through DCS as the probe (most relevant test)
    dcs_probe_response=$(read_terminal_response $'\ePtmux;\e\e]52;c;?\a\e\\' 1.0 2>/dev/null) || true

    if [[ -n "$dcs_probe_response" ]]; then
        field "DCS" "Passthrough probe .." "$(pass) (outer terminal responded)"
        summary_pass "DCS passthrough to outer terminal working"
    else
        field "DCS" "Passthrough probe .." "$(warn) (no response — outer terminal may not support OSC 52 read)"
        summary_warn "DCS passthrough probe got no response (outer terminal may not support OSC 52 read)"
    fi
}

# ─── Section 5: Tmux Config Audit ────────────────────────────────────────────

section_tmux_config() {
    header "TMUX CONFIG"

    if [[ -z "${TMUX:-}" ]]; then
        # Try to check config even outside tmux
        if command -v tmux &>/dev/null; then
            field "CFG" "Note .............." "Not inside tmux — showing default config"
            local set_clip
            set_clip=$(tmux start-server \; show -gv set-clipboard 2>/dev/null || echo "<unavailable>")
            field "CFG" "set-clipboard ....." "$set_clip"
        else
            field "CFG" "Status ............" "$(skip) tmux not installed"
        fi
        return
    fi

    # set-clipboard
    local set_clip
    set_clip=$(tmux show -gv set-clipboard 2>/dev/null || echo "<error>")
    field "CFG" "set-clipboard ....." "$set_clip"
    if [[ "$set_clip" == "on" ]]; then
        summary_pass "set-clipboard is on"
    elif [[ "$set_clip" == "external" ]]; then
        summary_pass "set-clipboard is external (apps can set, tmux won't)"
    else
        summary_warn "set-clipboard is '${set_clip}' — OSC 52 may not be forwarded"
    fi

    # allow-passthrough
    local passthrough
    passthrough=$(tmux show -gv allow-passthrough 2>/dev/null || echo "<error>")
    field "CFG" "allow-passthrough .." "$passthrough"

    # default-terminal
    local def_term
    def_term=$(tmux show -gv default-terminal 2>/dev/null || echo "<error>")
    field "CFG" "default-terminal .." "$def_term"

    # terminal-overrides
    local overrides
    overrides=$(tmux show -gv terminal-overrides 2>/dev/null || echo "<error>")

    # Check for Ms capability
    if [[ "$overrides" == *"Ms="* ]]; then
        field "CFG" "Ms capability ....." "$(pass) (found in terminal-overrides)"
        # Show relevant entries
        local ms_entries
        ms_entries=$(echo "$overrides" | tr ',' '\n' | grep -i 'Ms=' | head -3)
        while IFS= read -r entry; do
            [[ -n "$entry" ]] && field "CFG" "  override ........" "$entry"
        done <<< "$ms_entries"
    else
        field "CFG" "Ms capability ....." "$(warn) not found in terminal-overrides"
        summary_warn "Ms (OSC 52) capability not set in terminal-overrides"
    fi

    # escape-time
    local esc_time
    esc_time=$(tmux show -gv escape-time 2>/dev/null || echo "<error>")
    field "CFG" "escape-time ......." "${esc_time}ms"
    if [[ "$esc_time" -gt 100 ]] 2>/dev/null; then
        summary_warn "escape-time is ${esc_time}ms — consider reducing to 0-50ms"
    fi

    # Copy mode bindings that reference clipboard/yank
    local yank_bindings
    yank_bindings=$(tmux list-keys 2>/dev/null | grep -i 'yank\|osc\|clip\|copy-pipe' | head -5 || true)
    if [[ -n "$yank_bindings" ]]; then
        field "CFG" "Copy bindings:" ""
        while IFS= read -r line; do
            [[ -n "$line" ]] && printf "         %s\n" "$line"
        done <<< "$yank_bindings"
    fi

    # Detect copy-pipe scripts referenced in bindings
    local pipe_scripts
    pipe_scripts=$(tmux list-keys 2>/dev/null \
        | grep -oP 'copy-pipe(?:-and-cancel|-no-clear)?\s+"\K[^"]+' \
        | sort -u || true)

    if [[ -n "$pipe_scripts" ]]; then
        while IFS= read -r script_path; do
            [[ -z "$script_path" ]] && continue
            # Expand ~ to $HOME
            local expanded="${script_path/#\~/$HOME}"
            if [[ -x "$expanded" ]]; then
                field "CFG" "Copy pipe script .." "$(pass) (found at $expanded)"
            elif [[ -f "$expanded" ]]; then
                field "CFG" "Copy pipe script .." "$(warn) (found but not executable: $expanded)"
                summary_warn "Copy pipe script exists but not executable: $expanded"
            else
                field "CFG" "Copy pipe script .." "$(fail) (NOT FOUND: $expanded)"
                summary_fail "Copy pipe script not found: $expanded — copy bindings will silently fail"
            fi
        done <<< "$pipe_scripts"
    else
        field "CFG" "Copy pipe script .." "$(pass) (none — using tmux native clipboard)"
    fi
}

# ─── Main ─────────────────────────────────────────────────────────────────────

main() {
    local env_type
    env_type=$(detect_env_type)

    divider
    printf "${BOLD} TMUX DIAGNOSTICS${RESET}\n"
    printf " Environment: ${CYAN}%s${RESET}\n" "$env_type"
    printf " Date: %s\n" "$(date '+%Y-%m-%d %H:%M:%S')"
    printf " Host: %s\n" "$(hostname)"
    divider

    section_environment
    section_clipboard
    section_color_queries
    section_dcs_passthrough
    section_tmux_config

    # ─── Summary ──────────────────────────────────────────────────────────
    printf "\n"
    divider
    printf "${BOLD} SUMMARY${RESET}\n"
    divider

    for msg in "${SUMMARY_PASS[@]}"; do
        printf "  ${GREEN}✓${RESET} %s\n" "$msg"
    done
    for msg in "${SUMMARY_WARN[@]}"; do
        printf "  ${YELLOW}⚠${RESET} %s\n" "$msg"
    done
    for msg in "${SUMMARY_FAIL[@]}"; do
        printf "  ${RED}✗${RESET} %s\n" "$msg"
    done

    if [[ ${#SUMMARY_FAIL[@]} -eq 0 && ${#SUMMARY_WARN[@]} -eq 0 ]]; then
        printf "  ${GREEN}All checks passed!${RESET}\n"
    fi

    divider
    printf "\n"
}

main "$@"
