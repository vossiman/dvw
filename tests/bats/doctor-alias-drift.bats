#!/usr/bin/env bats
#
# review 2026-08-21: #49 reconciles an ssh alias only when that workspace is
# connected from THIS machine, so a block DevPod rewrote elsewhere keeps
# `ForwardAgent yes` / a forwarding ProxyCommand forever. The doctor scan must
# flag both drift kinds and stay quiet about conforming blocks.

setup() {
  source "$DVW_ROOT/dvw"
  export DVW_SSH_CONFIG="$BATS_TEST_TMPDIR/ssh.config"
}

@test "doctor alias drift: ForwardAgent yes is flagged as agent drift" {
  _dvw_ssh_alias_present() { return 0; }
  _dvw_extract_ssh_alias_block() {
    printf '# DevPod Start demo.devpod\nHost demo.devpod\n  ForwardAgent yes\n  ProxyCommand devpod ssh --stdio --agent-forwarding=false --context default --user codespace demo\n# DevPod End demo.devpod\n'
  }
  catalog_read() { printf '{"workspaces":[{"id":"demo"}]}'; }
  run _dvw_doctor_scan_alias_drift
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'demo\tagent')" ]
}

@test "doctor alias drift: a missing --agent-forwarding=false is flagged as proxy drift" {
  _dvw_ssh_alias_present() { return 0; }
  _dvw_extract_ssh_alias_block() {
    printf '# DevPod Start demo.devpod\nHost demo.devpod\n  ForwardAgent no\n  ProxyCommand devpod ssh --stdio --context default --user codespace demo\n# DevPod End demo.devpod\n'
  }
  catalog_read() { printf '{"workspaces":[{"id":"demo"}]}'; }
  run _dvw_doctor_scan_alias_drift
  [ "$status" -eq 0 ]
  [ "$output" = "$(printf 'demo\tproxy')" ]
}

@test "doctor alias drift: conforming blocks are silent" {
  _dvw_ssh_alias_present() { return 0; }
  _dvw_extract_ssh_alias_block() {
    printf '# DevPod Start demo.devpod\nHost demo.devpod\n  ForwardAgent no\n  ProxyCommand devpod ssh --stdio --agent-forwarding=false --context default --user codespace demo\n# DevPod End demo.devpod\n'
  }
  catalog_read() { printf '{"workspaces":[{"id":"demo"},{"id":"other"}]}'; }
  run _dvw_doctor_scan_alias_drift
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
