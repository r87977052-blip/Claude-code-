#!/data/data/com.termux/files/usr/bin/bash
#
# doctor.sh — diagnose a Claude Code on Android install (Termux + proot-distro).
#
# Run inside Termux:
#
#     bash mobile/doctor.sh [--distro NAME] [--deep]
#
#   --deep    also run `claude doctor` inside the container (slow, needs auth state)
#
# Exit status: 0 = everything ok, 1 = at least one failure.

set -uo pipefail

DISTRO="ubuntu"
DEEP=0
while [ $# -gt 0 ]; do
  case "$1" in
    --distro) DISTRO="${2:-ubuntu}"; shift ;;
    --distro=*) DISTRO="${1#*=}" ;;
    --deep) DEEP=1 ;;
    -h|--help) sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
  shift
done

if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""
fi

FAILURES=0
WARNINGS=0

report() { # report <label> <ok|warn|fail> <detail>
  local label="$1" status="$2" detail="$3" mark
  case "$status" in
    ok)   mark="${C_GREEN}ok${C_RESET}" ;;
    warn) mark="${C_YELLOW}warn${C_RESET}"; WARNINGS=$((WARNINGS + 1)) ;;
    fail) mark="${C_RED}fail${C_RESET}"; FAILURES=$((FAILURES + 1)) ;;
    *)    mark="$status" ;;
  esac
  printf '  [%b] %-24s %s\n' "$mark" "$label" "$detail"
}

section() { printf '\n%s\n' "${C_BLUE}$*${C_RESET}"; }

WRAPPER="${PREFIX:-/data/data/com.termux/files/usr}/bin/claude"

section "Host (Termux / Android)"

arch="$(uname -m 2>/dev/null || echo unknown)"
case "$arch" in
  aarch64|arm64) report "cpu" ok "$arch" ;;
  # x86_64 turns up on emulators, Chromebooks and CI runs of tests/selftest.sh.
  # There is no android-x64 build published, so it cannot work on a device, but
  # it is not a broken install either — warn rather than fail.
  x86_64) report "cpu" warn "$arch — no phone runs this; Claude Code publishes no android-x64 build" ;;
  *) report "cpu" fail "$arch — Claude Code has no build for this architecture" ;;
esac

if [ -n "${PREFIX:-}" ] && [ -d /data/data/com.termux ]; then
  report "termux" ok "PREFIX=${PREFIX}"
elif [ -n "${PREFIX:-}" ]; then
  # Other Linux-on-Android hosts (UserLAnd, Andronix) and the self-test set
  # PREFIX but are not the Termux app.
  report "termux" warn "PREFIX=${PREFIX} but /data/data/com.termux is absent — not the Termux app"
else
  report "termux" fail "not running inside Termux (PREFIX is unset)"
fi

GETPROP=""
command -v getprop >/dev/null 2>&1 && GETPROP="getprop"
[ -z "$GETPROP" ] && [ -x /system/bin/getprop ] && GETPROP="/system/bin/getprop"
if [ -n "$GETPROP" ]; then
  report "android" ok "SDK $($GETPROP ro.build.version.sdk 2>/dev/null || echo '?') / Android $($GETPROP ro.build.version.release 2>/dev/null || echo '?')"
else
  report "android" warn "getprop unavailable"
fi

free_kb="$(df -Pk "${PREFIX:-$PWD}" 2>/dev/null | awk 'NR==2 {print $4}')"
if [ -n "${free_kb:-}" ]; then
  free_mb=$((free_kb / 1024))
  if [ "$free_mb" -ge 2000 ]; then report "free space" ok "${free_mb} MB"
  else report "free space" warn "${free_mb} MB free — updates may fail"; fi
fi

mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
[ -n "${mem_kb:-}" ] && report "ram" ok "$((mem_kb / 1024)) MB"

section "Termux packages"

for tool in proot-distro curl git; do
  if command -v "$tool" >/dev/null 2>&1; then
    report "$tool" ok "$(command -v "$tool")"
  else
    report "$tool" fail "missing — run: pkg install $tool"
  fi
done

if command -v tmux >/dev/null 2>&1; then
  report "tmux" ok "$(tmux -V 2>/dev/null || echo installed)"
else
  report "tmux" warn "not installed (optional; needed for claude-tmux)"
fi

section "Container: ${DISTRO}"

if command -v proot-distro >/dev/null 2>&1; then
  report "proot-distro version" ok "$(proot-distro --version 2>/dev/null | head -1 || echo unknown)"
  if proot-distro login "$DISTRO" --work-dir "${HOME:-/}" -- /bin/true >/dev/null 2>&1; then
    report "container exec" ok "'${DISTRO}' is installed and can run commands"
  else
    report "container exec" fail "'${DISTRO}' is missing or broken — run: proot-distro install ${DISTRO}"
  fi
else
  report "container exec" fail "proot-distro is not installed"
fi

section "Claude Code launcher"

if [ -x "$WRAPPER" ]; then
  report "launcher" ok "$WRAPPER"
  grep -q '@@' "$WRAPPER" && report "launcher template" fail "placeholders were not substituted — re-run install.sh"
  baked_distro="$(sed -n 's/^DISTRO="\(.*\)"$/\1/p' "$WRAPPER" | head -1)"
  baked_bin="$(sed -n 's/^CLAUDE_BIN="\(.*\)"$/\1/p' "$WRAPPER" | head -1)"
  report "launcher target" ok "distro='${baked_distro:-?}' claude='${baked_bin:-?}'"
else
  report "launcher" fail "$WRAPPER is missing or not executable — re-run mobile/install.sh"
fi

if [ -x "$WRAPPER" ]; then
  if version_out="$("$WRAPPER" --version 2>&1)"; then
    report "claude --version" ok "$(printf '%s' "$version_out" | tail -1)"
  else
    report "claude --version" fail "$(printf '%s' "$version_out" | tail -3 | tr '\n' ' ')"
  fi
fi

section "Network"

if command -v curl >/dev/null 2>&1; then
  for host in https://api.anthropic.com/ https://claude.ai/install.sh; do
    code="$(curl -sS -m 20 -o /dev/null -w '%{http_code}' "$host" 2>/dev/null || echo 000)"
    case "$code" in
      000)     report "$(printf '%s' "$host" | sed 's|https://||; s|/.*||')" fail "unreachable (check Wi-Fi/data, VPN or DNS)" ;;
      4??|2??) report "$(printf '%s' "$host" | sed 's|https://||; s|/.*||')" ok "HTTP ${code}" ;;
      *)       report "$(printf '%s' "$host" | sed 's|https://||; s|/.*||')" warn "HTTP ${code}" ;;
    esac
  done
else
  report "network" warn "curl missing — cannot test connectivity"
fi

section "Android power management"

if command -v termux-wake-lock >/dev/null 2>&1; then
  report "termux-wake-lock" ok "available — run it before long sessions"
else
  report "termux-wake-lock" warn "not found — install Termux:API (pkg install termux-api)"
fi

SETTINGS=""
command -v settings >/dev/null 2>&1 && SETTINGS="settings"
[ -z "$SETTINGS" ] && [ -x /system/bin/settings ] && SETTINGS="/system/bin/settings"
if [ -n "$SETTINGS" ]; then
  phantom="$($SETTINGS get global settings_enable_monitor_phantom_procs 2>/dev/null || echo unknown)"
  case "$phantom" in
    false) report "phantom proc killer" ok "disabled (settings_enable_monitor_phantom_procs=false)" ;;
    true)  report "phantom proc killer" warn "enabled — long sessions can die with signal 9; see README" ;;
    *)     report "phantom proc killer" warn "state unknown (${phantom})" ;;
  esac
else
  report "phantom proc killer" warn "settings command unavailable"
fi

if [ "$DEEP" = 1 ] && [ -x "$WRAPPER" ]; then
  section "claude doctor (inside the container)"
  "$WRAPPER" doctor 2>&1 | sed 's/^/    /' || true
fi

printf '\n'
if [ "$FAILURES" -gt 0 ]; then
  printf '%s\n' "${C_RED}${FAILURES} failure(s), ${WARNINGS} warning(s).${C_RESET}"
  exit 1
fi
printf '%s\n' "${C_GREEN}No failures.${C_RESET} ${WARNINGS} warning(s)."
exit 0
