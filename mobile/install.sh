#!/data/data/com.termux/files/usr/bin/bash
#
# install.sh — install Claude Code on an Android phone (Termux + proot-distro Ubuntu).
#
# Run this INSIDE Termux on the phone:
#
#     bash install.sh
#
# Why a script is needed at all:
#   Claude Code 2.x ships as a prebuilt native binary per platform. The published
#   set is darwin-arm64/x64, linux-x64/arm64 (glibc), linux-x64/arm64-musl and
#   win32-x64/arm64 — there is no android-arm64 build, so `npm i -g
#   @anthropic-ai/claude-code` in Termux ends with
#   "Native binaries for linux-arm64-android are not available on this release
#   channel." The linux-arm64 binary itself is dynamically linked against
#   /lib/ld-linux-aarch64.so.1 + libc.so.6, which Android's Bionic libc does not
#   provide. This script puts a real glibc userland (Ubuntu) inside Termux with
#   proot-distro and installs Claude Code there with Anthropic's own installer.
#
# Usage:
#   bash install.sh [options]
#
# Options:
#   --check            Run the preflight checks and exit (installs nothing).
#   --distro NAME      Container to use (default: ubuntu).
#   --with-tmux        Also install tmux and a `claude-tmux` helper.
#   --skip-packages    Do not run pkg update/install (assume packages exist).
#   --force            Continue on a non-Termux or non-aarch64 system.
#                      (used by tests/selftest.sh, or other Linux-on-Android apps)
#   -y, --yes          Do not ask for confirmation.
#   -h, --help         Show this help.
#
# Environment overrides:
#   CLAUDE_PROOT_EXTRA_ARGS   Extra arguments baked into the generated launcher,
#                             e.g. "-b /sdcard/code:/sdcard/code".

set -uo pipefail

SCRIPT_VERSION="1.0.0"
DISTRO="ubuntu"
MIN_FREE_MB=3000      # Ubuntu rootfs + claude binary (~250 MB) + apt overhead.
MIN_SDK=26            # Android 8.0 — proot needs the newer syscall surface.
INSTALLER_URL="https://claude.ai/install.sh"

CHECK_ONLY=0
FORCE=0
WITH_TMUX=0
SKIP_PACKAGES=0
ASSUME_YES=0

# --------------------------------------------------------------------------- #
# logging
# --------------------------------------------------------------------------- #
if [ -t 1 ]; then
  C_RESET=$'\033[0m'; C_RED=$'\033[31m'; C_GREEN=$'\033[32m'
  C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_DIM=$'\033[2m'
else
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_DIM=""
fi

info()  { printf '%s\n' "${C_BLUE}==>${C_RESET} $*"; }
note()  { printf '%s\n' "${C_DIM}    $*${C_RESET}"; }
warn()  { printf '%s\n' "${C_YELLOW}warning:${C_RESET} $*" >&2; }
die()   { printf '%s\n' "${C_RED}error:${C_RESET} $*" >&2; exit 1; }

usage() { sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'; }

# --------------------------------------------------------------------------- #
# arguments
# --------------------------------------------------------------------------- #
while [ $# -gt 0 ]; do
  case "$1" in
    --check)          CHECK_ONLY=1 ;;
    --distro)         DISTRO="${2:-}"; [ -n "$DISTRO" ] || die "--distro needs a value"; shift ;;
    --distro=*)       DISTRO="${1#*=}" ;;
    --with-tmux)      WITH_TMUX=1 ;;
    --skip-packages)  SKIP_PACKAGES=1 ;;
    --force)          FORCE=1 ;;
    -y|--yes)         ASSUME_YES=1 ;;
    -h|--help)        usage; exit 0 ;;
    *)                printf '%s\n' "unknown option: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

HELPER_DIR="${HOME:-/tmp}/.claude-android"
WRAPPER="${PREFIX:-/data/data/com.termux/files/usr}/bin/claude"

# --------------------------------------------------------------------------- #
# preflight
# --------------------------------------------------------------------------- #
CHECK_FAILED=0
CHECK_WARNED=0

report() { # report <label> <ok|warn|fail> <detail>
  local label="$1" status="$2" detail="$3" mark
  case "$status" in
    ok)   mark="${C_GREEN}ok${C_RESET}" ;;
    warn) mark="${C_YELLOW}warn${C_RESET}"; CHECK_WARNED=$((CHECK_WARNED + 1)) ;;
    fail) mark="${C_RED}fail${C_RESET}"; CHECK_FAILED=$((CHECK_FAILED + 1)) ;;
    *)    mark="$status" ;;
  esac
  printf '  [%b] %-22s %s\n' "$mark" "$label" "$detail"
}

preflight() {
  info "Preflight checks (install.sh v${SCRIPT_VERSION})"

  # 1. bash version — arrays and ${var,,} need bash 4+.
  if [ "${BASH_VERSINFO[0]:-0}" -ge 4 ]; then
    report "bash" ok "bash ${BASH_VERSION}"
  else
    report "bash" fail "bash 4+ required (found ${BASH_VERSION:-none})"
  fi

  # 2. Termux.
  if [ -n "${PREFIX:-}" ] && [ -d "${PREFIX}/bin" ] && [ -d /data/data/com.termux ]; then
    report "termux" ok "PREFIX=${PREFIX}"
  elif [ "$FORCE" = 1 ]; then
    report "termux" warn "not Termux — continuing because --force was given"
  else
    report "termux" fail "run this inside Termux (or pass --force)"
  fi

  # 3. CPU architecture. Claude Code publishes linux-arm64 and linux-x64 only.
  local arch; arch="$(uname -m 2>/dev/null || echo unknown)"
  case "$arch" in
    aarch64|arm64)  report "cpu" ok "$arch (64-bit ARM)" ;;
    x86_64)
      if [ "$FORCE" = 1 ]; then report "cpu" warn "$arch — x86_64, allowed by --force"
      else report "cpu" fail "$arch — a phone must report aarch64"; fi ;;
    armv7l|armv8l)  report "cpu" fail "$arch — 32-bit userland; Claude Code has no armv7 build" ;;
    *)              report "cpu" fail "$arch — unsupported" ;;
  esac

  # 4. Android version.
  local sdk=""
  if command -v getprop >/dev/null 2>&1; then
    sdk="$(getprop ro.build.version.sdk 2>/dev/null || true)"
  elif [ -x /system/bin/getprop ]; then
    sdk="$(/system/bin/getprop ro.build.version.sdk 2>/dev/null || true)"
  fi
  if [ -n "$sdk" ]; then
    if [ "$sdk" -ge "$MIN_SDK" ] 2>/dev/null; then
      report "android" ok "SDK ${sdk} ($(/system/bin/getprop ro.build.version.release 2>/dev/null || echo '?'))"
    else
      report "android" fail "SDK ${sdk} is older than ${MIN_SDK} (Android 8.0)"
    fi
  else
    report "android" warn "getprop not found (not running on Android?)"
  fi

  # 5. Free space on the filesystem that holds PREFIX.
  local fs_root="${PREFIX:-$PWD}" free_kb free_mb
  free_kb="$(df -Pk "$fs_root" 2>/dev/null | awk 'NR==2 {print $4}')"
  if [ -n "${free_kb:-}" ]; then
    free_mb=$((free_kb / 1024))
    if [ "$free_mb" -ge "$MIN_FREE_MB" ]; then
      report "free space" ok "${free_mb} MB on ${fs_root}"
    else
      report "free space" fail "${free_mb} MB — need at least ${MIN_FREE_MB} MB"
    fi
  else
    report "free space" warn "could not read df output for ${fs_root}"
  fi

  # 6. RAM. Claude Code is a ~250 MB binary; 4 GB devices are fine but tight.
  local mem_kb mem_mb
  mem_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || true)"
  if [ -n "${mem_kb:-}" ]; then
    mem_mb=$((mem_kb / 1024))
    if [ "$mem_mb" -ge 3500 ]; then report "ram" ok "${mem_mb} MB"
    else report "ram" warn "${mem_mb} MB — workable, expect it to be slow"; fi
  else
    report "ram" warn "/proc/meminfo unreadable"
  fi

  # 7. Network. Warnings only: a captive portal or a blocked CDN should not stop
  #    the install of local packages, and the real failure shows up later anyway.
  if command -v curl >/dev/null 2>&1; then
    if curl -fsS -m 20 -o /dev/null "$INSTALLER_URL" 2>/dev/null; then
      report "network" ok "claude.ai reachable"
    else
      report "network" warn "could not reach claude.ai yet (curl is installed after pkg step)"
    fi
  else
    report "network" warn "curl not installed yet — will be checked after the pkg step"
  fi

  # 8. Existing install.
  if [ -x "$WRAPPER" ]; then
    report "existing install" warn "$WRAPPER already exists — it will be overwritten"
  else
    report "existing install" ok "no launcher at $WRAPPER yet"
  fi

  if [ "$CHECK_FAILED" -gt 0 ]; then
    printf '%s\n' "${C_RED}${CHECK_FAILED} check(s) failed.${C_RESET}" >&2
    return 1
  fi
  if [ "$CHECK_WARNED" -gt 0 ]; then
    printf '%s\n' "${C_YELLOW}${CHECK_WARNED} warning(s); continuing.${C_RESET}"
  fi
  return 0
}

# --------------------------------------------------------------------------- #
# helpers
# --------------------------------------------------------------------------- #
pkg_run() { # pkg_run <apt args...> — retries transient apt failures.
  local attempt=1
  while :; do
    if DEBIAN_FRONTEND=noninteractive pkg "$@"; then return 0; fi
    if [ "$attempt" -ge 3 ]; then
      warn "pkg $* failed after ${attempt} attempts"
      return 1
    fi
    warn "pkg $* failed (attempt ${attempt}/3) — retrying in 5 s"
    attempt=$((attempt + 1))
    sleep 5
  done
}

distro_probe() { # distro_probe — succeeds when the container is installed and can exec.
  command -v proot-distro >/dev/null 2>&1 || return 1
  proot-distro login "$DISTRO" --work-dir "${HOME:-/}" -- /bin/true >/dev/null 2>&1
}

in_distro() { # in_distro <script body> — run a script inside the container.
  local body="$1" script="${HELPER_DIR}/run-inside.sh"
  mkdir -p "$HELPER_DIR" || die "cannot create ${HELPER_DIR}"
  {
    printf '%s\n' '#!/bin/bash'
    printf '%s\n' 'set -euo pipefail'
    printf '%s\n' "$body"
  } > "$script" || die "cannot write ${script}"
  chmod 0755 "$script"
  # proot-distro binds the Termux $HOME at the same path inside the container,
  # so the script is visible to the guest at this exact location.
  proot-distro login "$DISTRO" --work-dir "${HOME:-/}" -- /bin/bash "$script"
}

# --------------------------------------------------------------------------- #
# steps
# --------------------------------------------------------------------------- #
ensure_packages() {
  info "Installing Termux packages"
  pkg_run update -y || die "pkg update failed — check your connection, then re-run"
  local pkgs=(proot-distro curl git ca-certificates)
  [ "$WITH_TMUX" = 1 ] && pkgs+=(tmux)
  pkg_run install -y "${pkgs[@]}" || die "pkg install failed"
  command -v proot-distro >/dev/null 2>&1 || die "proot-distro is still not on PATH after pkg install"
  note "proot-distro $(proot-distro --version 2>/dev/null | head -1 || echo 'installed')"
}

ensure_distro() {
  if distro_probe; then
    info "Container '${DISTRO}' is already installed — reusing it"
    return 0
  fi
  info "Creating the '${DISTRO}' container (this downloads an image, a few hundred MB)"
  note "proot-distro 5.x pulls images from Docker Hub — registry-1.docker.io must be reachable"
  proot-distro install "$DISTRO" || die "proot-distro install ${DISTRO} failed"
  distro_probe || die "the '${DISTRO}' container was created but cannot exec — run: proot-distro login ${DISTRO}"
}

install_claude_in_distro() {
  info "Installing Claude Code inside '${DISTRO}' with Anthropic's official installer"
  in_distro '
    export DEBIAN_FRONTEND=noninteractive

    echo "[guest] apt-get update"
    apt-get update -y

    echo "[guest] installing prerequisites"
    apt-get install -y --no-install-recommends ca-certificates curl git tar xz-utils less

    echo "[guest] downloading the official installer"
    curl -fsSL "'"${INSTALLER_URL}"'" -o /tmp/claude-install.sh

    echo "[guest] running the official installer"
    bash /tmp/claude-install.sh

    echo "[guest] locating the claude binary"
    for candidate in "$HOME/.local/bin/claude" /usr/local/bin/claude /usr/bin/claude; do
      if [ -x "$candidate" ]; then
        echo "[guest] installed at $candidate"
        "$candidate" --version
        exit 0
      fi
    done
    if command -v claude >/dev/null 2>&1; then
      echo "[guest] installed at $(command -v claude)"
      claude --version
      exit 0
    fi
    echo "[guest] the installer finished but no claude binary was found" >&2
    exit 1
  ' || die "the in-container install failed — re-run to retry, or run: proot-distro login ${DISTRO}"
}

locate_claude() { # locate_claude — echoes the absolute path of claude inside the container.
  in_distro '
    for candidate in "$HOME/.local/bin/claude" /usr/local/bin/claude /usr/bin/claude; do
      if [ -x "$candidate" ]; then
        printf "%s\n" "$candidate"
        exit 0
      fi
    done
    if command -v claude >/dev/null 2>&1; then
      command -v claude
      exit 0
    fi
    exit 1
  ' 2>/dev/null | tail -1
}

write_wrapper() { # write_wrapper <path to claude inside the container>
  local claude_bin="$1" shell_bin
  shell_bin="${PREFIX:-}/bin/bash"
  [ -x "$shell_bin" ] || shell_bin="$(command -v bash)"

  mkdir -p "$(dirname "$WRAPPER")" || die "cannot create $(dirname "$WRAPPER")"
  cat > "$WRAPPER" <<'LAUNCHER'
#!@@BASH@@
# claude — launch Claude Code inside the proot-distro container "@@DISTRO@@".
# Generated by mobile/install.sh; re-running the installer rewrites this file.
set -uo pipefail

PROOT_DISTRO="@@PROOT_DISTRO@@"
DISTRO="@@DISTRO@@"
CLAUDE_BIN="@@CLAUDE_BIN@@"

if [ ! -x "$PROOT_DISTRO" ]; then
  if command -v proot-distro >/dev/null 2>&1; then
    PROOT_DISTRO="$(command -v proot-distro)"
  else
    echo "claude: proot-distro is missing — install it with: pkg install proot-distro" >&2
    exit 127
  fi
fi

# proot-distro binds the Termux home directory and /storage into the container at
# their original paths, so anything under those is usable as a working directory.
# Anything else (e.g. $PREFIX) does not exist in the guest — fall back to $HOME.
WD="$(pwd -P 2>/dev/null || printf '%s' "$HOME")"
case "$WD" in
  "$HOME"|"$HOME"/*|/storage/*|/sdcard/*) ;;
  *) WD="$HOME" ;;
esac

EXTRA=()
if [ -n "${CLAUDE_PROOT_EXTRA_ARGS:-}" ]; then
  read -r -a EXTRA <<<"$CLAUDE_PROOT_EXTRA_ARGS"
fi

exec "$PROOT_DISTRO" login "$DISTRO" "${EXTRA[@]}" --work-dir "$WD" -- "$CLAUDE_BIN" "$@"
LAUNCHER

  local pd_bin; pd_bin="$(command -v proot-distro || printf '%s' "${PREFIX:-}/bin/proot-distro")"
  sed -e "s|@@BASH@@|${shell_bin}|" \
      -e "s|@@PROOT_DISTRO@@|${pd_bin}|" \
      -e "s|@@DISTRO@@|${DISTRO}|" \
      -e "s|@@CLAUDE_BIN@@|${claude_bin}|" \
      -i "$WRAPPER" 2>/dev/null || {
        # busybox/sed without -i support: rewrite through a temp file.
        local tmp="${WRAPPER}.tmp"
        sed -e "s|@@BASH@@|${shell_bin}|" \
            -e "s|@@PROOT_DISTRO@@|${pd_bin}|" \
            -e "s|@@DISTRO@@|${DISTRO}|" \
            -e "s|@@CLAUDE_BIN@@|${claude_bin}|" "$WRAPPER" > "$tmp" && mv "$tmp" "$WRAPPER"
      }
  chmod 0755 "$WRAPPER" || die "cannot chmod ${WRAPPER}"
  info "Launcher written to ${WRAPPER}"
  note "claude inside the container: ${claude_bin}"
}

write_tmux_helper() {
  local helper="${PREFIX:-/data/data/com.termux/files/usr}/bin/claude-tmux"
  command -v tmux >/dev/null 2>&1 || { warn "tmux is not installed — skipping claude-tmux"; return 0; }
  cat > "$helper" <<'TMUXHELPER'
#!/data/data/com.termux/files/usr/bin/bash
# claude-tmux — run Claude Code in a named tmux session that survives screen-off.
set -uo pipefail
SESSION="${1:-claude}"
if tmux has-session -t "$SESSION" 2>/dev/null; then
  exec tmux attach -t "$SESSION"
fi
command -v termux-wake-lock >/dev/null 2>&1 && termux-wake-lock
exec tmux new-session -s "$SESSION" "claude; echo; echo '[claude exited — press Enter]'; read -r"
TMUXHELPER
  sed -i "s|^#!/data/data/com.termux/files/usr/bin/bash|#!${PREFIX:-}/bin/bash|" "$helper" 2>/dev/null || true
  chmod 0755 "$helper"
  info "tmux helper written to ${helper}  (usage: claude-tmux [session-name])"
}

verify() {
  info "Verifying the install"
  local out
  if out="$("$WRAPPER" --version 2>&1)"; then
    note "$out"
    return 0
  fi
  warn "the launcher did not run cleanly. Output:"
  printf '%s\n' "$out" >&2
  return 1
}

print_next_steps() {
  cat <<EOF

${C_GREEN}Claude Code is installed.${C_RESET}

Next steps, in Termux:

  1. Start it:            claude
  2. Sign in:             type /login  (or: claude auth login)
                          Termux will print a https://claude.ai/... URL — open it in
                          the phone's browser, approve, and the browser is redirected
                          back to a localhost page that completes the sign-in.
                          Alternative: export ANTHROPIC_API_KEY=sk-ant-... in ~/.bashrc
  3. Keep sessions alive: termux-wake-lock
                          Settings > Apps > Termux > Battery > "Allow background activity"
                          Lock the Termux card in Recents (swipe down on it) so ColorOS
                          does not kill it.
  4. Health check:        bash mobile/doctor.sh      (or: claude doctor)
  5. Update later:        claude update              (inside the container)

Working on a project:

  cd ~/my-project   # any directory under \$HOME or /storage is visible inside
  claude            # the container at the same path

Keyboard: Claude Code needs ESC, TAB, CTRL and the arrow keys. Enable Termux's
extra-keys row:

  mkdir -p ~/.termux
  echo "extra-keys = [['ESC','/','-','HOME','UP','END'],['TAB','CTRL','ALT','LEFT','DOWN','RIGHT']]" >> ~/.termux/termux.properties
  termux-reload-settings

If Android kills long sessions ("Process completed (signal 9)"), see the
phantom-process-killer section of mobile/README.md.
EOF
}

# --------------------------------------------------------------------------- #
# main
# --------------------------------------------------------------------------- #
main() {
  preflight || die "preflight failed — fix the failures above, or re-run with --force"
  if [ "$CHECK_ONLY" = 1 ]; then
    info "--check given; nothing was installed"
    exit 0
  fi

  if [ "$ASSUME_YES" != 1 ]; then
    printf '\nThis will install proot-distro + a %s container (~2 GB) and Claude Code inside it.\n' "$DISTRO"
    printf 'Continue? [Y/n] '
    read -r reply
    case "${reply:-y}" in
      [nN]*) info "aborted by user"; exit 1 ;;
    esac
  fi

  [ "$SKIP_PACKAGES" = 1 ] || ensure_packages
  command -v proot-distro >/dev/null 2>&1 || die "proot-distro is not on PATH"
  ensure_distro
  install_claude_in_distro

  local claude_bin
  claude_bin="$(locate_claude)"
  [ -n "$claude_bin" ] || die "could not locate the claude binary inside '${DISTRO}'"
  write_wrapper "$claude_bin"
  [ "$WITH_TMUX" = 1 ] && write_tmux_helper

  verify || warn "install finished but verification failed — run 'bash mobile/doctor.sh' to diagnose"
  print_next_steps
}

main "$@"
