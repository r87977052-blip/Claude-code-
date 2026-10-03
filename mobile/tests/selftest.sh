#!/usr/bin/env bash
#
# selftest.sh — integration test for mobile/install.sh and mobile/doctor.sh.
#
# It runs the REAL installer end to end, but against stub `pkg`, `proot-distro`,
# `apt-get` and `curl` commands in a throwaway PREFIX, so it can run on any
# Linux/macOS machine (CI included) without an Android phone. The stubs imitate
# proot-distro 5.9.0, the version Termux currently packages:
#
#   proot-distro install <name>            creates a container marker
#   proot-distro login <name> [opts] -- CMD  fails if the marker is missing,
#                                          otherwise runs CMD with a "guest" PATH
#
# Run:  bash mobile/tests/selftest.sh
#
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MOBILE_DIR="$(cd "$HERE/.." && pwd)"
INSTALL_SH="$MOBILE_DIR/install.sh"
DOCTOR_SH="$MOBILE_DIR/doctor.sh"

[ -f "$INSTALL_SH" ] || { echo "cannot find $INSTALL_SH" >&2; exit 2; }
[ -f "$DOCTOR_SH" ]  || { echo "cannot find $DOCTOR_SH" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/claude-android-selftest.XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

export PREFIX="$WORK/usr"
export HOME="$WORK/home"
export CCT_LOG="$WORK/calls.log"
export CCT_STATE="$WORK/state"
export CCT_STUBS="$WORK/stubs"
export CCT_GUESTBIN="$WORK/guestbin"

mkdir -p "$PREFIX/bin" "$HOME" "$WORK/bin" "$CCT_STUBS" "$CCT_GUESTBIN" "$CCT_STATE"
: > "$CCT_LOG"

# The stub prefix dir comes first so `pkg` resolves to the stub, and $PREFIX/bin
# is on PATH the way Termux puts it.
export PATH="$PREFIX/bin:$WORK/bin:$PATH"

# --------------------------------------------------------------------------- #
# stubs
# --------------------------------------------------------------------------- #
cat > "$CCT_STUBS/pkg" <<'STUB'
#!/usr/bin/env bash
echo "pkg $*" >> "$CCT_LOG"
sub="${1:-}"; shift || true
[ "${1:-}" = "-y" ] && shift
case "$sub" in
  update) exit 0 ;;
  install)
    for p in "$@"; do
      case "$p" in
        proot-distro|tmux)
          printf '#!/usr/bin/env bash\nexec "%s/%s" "$@"\n' "$CCT_STUBS" "$p" > "$PREFIX/bin/$p"
          chmod 0755 "$PREFIX/bin/$p"
          ;;
      esac
    done
    exit 0 ;;
esac
exit 0
STUB

cat > "$CCT_STUBS/proot-distro" <<'STUB'
#!/usr/bin/env bash
echo "proot-distro $*" >> "$CCT_LOG"
cmd="${1:-}"; shift || true
case "$cmd" in
  --version) echo "5.9.0-selftest" ;;
  list)
    if [ -d "$CCT_STATE" ] && [ -n "$(ls -A "$CCT_STATE" 2>/dev/null)" ]; then
      for c in "$CCT_STATE"/*; do echo "  $(basename "$c")  installed"; done
    else
      echo "No containers are installed."
    fi ;;
  install)
    name="${1:?install needs a container name}"
    mkdir -p "$CCT_STATE/$name" ;;
  login)
    name="${1:?login needs a container name}"; shift
    if [ ! -d "$CCT_STATE/$name" ]; then
      echo "Error: container '$name' is not installed." >&2
      exit 1
    fi
    while [ $# -gt 0 ] && [ "$1" != "--" ]; do shift; done
    [ "${1:-}" = "--" ] && shift
    if [ $# -eq 0 ]; then echo "stub: login needs a command after --" >&2; exit 2; fi
    # The guest shares $HOME with the host (proot-distro binds the Termux home at
    # its original path), so HOME is deliberately left untouched here.
    PATH="$CCT_GUESTBIN:$PATH" exec "$@" ;;
  *) echo "stub proot-distro: unhandled command '$cmd'" >&2; exit 2 ;;
esac
STUB

cat > "$CCT_STUBS/tmux" <<'STUB'
#!/usr/bin/env bash
echo "tmux $*" >> "$CCT_LOG"
case "${1:-}" in
  -V) echo "tmux 3.5a-selftest" ;;
  has-session) exit 1 ;;
  *) exit 0 ;;
esac
STUB

# Host-side curl: always "reachable", answers -w '%{http_code}' with 200.
cat > "$WORK/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "curl $*" >> "$CCT_LOG"
out=""; fmt=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="${2:-}"; shift 2 ;;
    -w) fmt="${2:-}"; shift 2 ;;
    -*) shift ;;
    *)  url="$1"; shift ;;
  esac
done
if [ -n "$out" ] && [ "$out" != "/dev/null" ]; then : > "$out"; fi
case "$fmt" in *'%{http_code}'*) printf '200' ;; esac
exit 0
STUB

# Guest-side tools.
cat > "$CCT_GUESTBIN/apt-get" <<'STUB'
#!/usr/bin/env bash
echo "apt-get $*" >> "$CCT_LOG"
exit 0
STUB

cat > "$CCT_GUESTBIN/curl" <<'STUB'
#!/usr/bin/env bash
echo "guest curl $*" >> "$CCT_LOG"
out=""; url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="${2:-}"; shift 2 ;;
    -*) shift ;;
    *)  url="$1"; shift ;;
  esac
done
case "$url" in
  *claude.ai/install.sh*)
    [ -n "$out" ] || out="/dev/stdout"
    cat > "$out" <<'FAKEINSTALLER'
#!/bin/bash
echo "[stub installer] installing claude into $HOME/.local/bin"
mkdir -p "$HOME/.local/bin"
printf '#!/bin/bash\necho "9.9.9-selftest (Claude Code)"\n' > "$HOME/.local/bin/claude"
chmod 0755 "$HOME/.local/bin/claude"
FAKEINSTALLER
    exit 0 ;;
esac
echo "stub guest curl: unhandled url '$url'" >&2
exit 1
STUB

chmod 0755 "$CCT_STUBS"/* "$WORK/bin/curl" "$CCT_GUESTBIN"/*

# `pkg` only exists on Android — expose the stub on PATH. proot-distro is
# deliberately NOT here: install.sh must obtain it from $PREFIX/bin, which is
# what the pkg stub creates, exactly as it happens on a phone.
printf '#!/usr/bin/env bash\nexec "%s/pkg" "$@"\n' "$CCT_STUBS" > "$WORK/bin/pkg"
chmod 0755 "$WORK/bin/pkg"

# --------------------------------------------------------------------------- #
# assertions
# --------------------------------------------------------------------------- #
PASS=0; FAIL=0
ok()  { printf '  %s\n' "ok    $1"; PASS=$((PASS + 1)); }
no()  { printf '  %s\n' "FAIL  $1"; FAIL=$((FAIL + 1)); }
section() { printf '\n%s\n' "$*"; }

check() { # check <label> <actual> <expected>
  if [ "$2" = "$3" ]; then ok "$1"; else no "$1 (got '$2', want '$3')"; fi
}
assert_log() { # assert_log <needle> <label>
  if grep -qF -- "$1" "$CCT_LOG"; then ok "$2"; else no "$2 — log has no line matching: $1"; fi
}
assert_file() {
  if [ -e "$1" ]; then ok "$2"; else no "$2 — missing $1"; fi
}

# --------------------------------------------------------------------------- #
# 1. --check must pass on a non-Termux box when --force is given, and must not
#    install anything.
# --------------------------------------------------------------------------- #
section "1. preflight (--check --force)"
out="$(bash "$INSTALL_SH" --check --force 2>&1)"; rc=$?
check "--check exits 0" "$rc" "0"
if grep -q "Preflight checks" <<<"$out"; then ok "--check prints the preflight report"; else no "--check prints the preflight report"; fi
if [ ! -e "$PREFIX/bin/claude" ]; then ok "--check installed nothing"; else no "--check installed nothing"; fi

# Without --force the Termux check must fail the run.
out="$(bash "$INSTALL_SH" --check 2>&1)"; rc=$?
check "--check without --force fails off-Termux" "$rc" "1"

# --------------------------------------------------------------------------- #
# 2. full install
# --------------------------------------------------------------------------- #
section "2. install (--force --yes)"
: > "$CCT_LOG"
out="$(bash "$INSTALL_SH" --force --yes 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then printf '%s\n' "$out" | sed 's/^/    | /'; fi
check "install exits 0" "$rc" "0"

assert_log "pkg update -y"                                             "ran pkg update"
assert_log "pkg install -y proot-distro curl git ca-certificates"       "ran pkg install with the expected package set"
assert_log "proot-distro install ubuntu"                                "created the ubuntu container"
assert_log "apt-get update -y"                                          "apt-get update ran inside the container"
assert_log "apt-get install -y --no-install-recommends ca-certificates curl git tar xz-utils less" \
                                                                        "guest prerequisites installed"
assert_log "curl -fsSL https://claude.ai/install.sh -o /tmp/claude-install.sh" \
                                                                        "downloaded the official installer"
# The guest installer's stdout flows through install.sh to the terminal, so it is
# in the captured output rather than in the stub call log.
if grep -qF "[stub installer] installing claude into $HOME/.local/bin" <<<"$out"; then ok "official installer was executed"
else no "official installer was executed — not in the install output"; fi

assert_file "$HOME/.local/bin/claude" "claude binary exists in the container home"
assert_file "$PREFIX/bin/claude"      "launcher written to \$PREFIX/bin/claude"
[ -x "$PREFIX/bin/claude" ] && ok "launcher is executable" || no "launcher is executable"
if grep -q '@@' "$PREFIX/bin/claude"; then no "launcher has no unsubstituted placeholders"
else ok "launcher has no unsubstituted placeholders"; fi
if grep -qF 'DISTRO="ubuntu"' "$PREFIX/bin/claude"; then ok "launcher baked in the container name"
else no "launcher baked in the container name"; fi
if grep -qF "CLAUDE_BIN=\"$HOME/.local/bin/claude\"" "$PREFIX/bin/claude"; then ok "launcher baked in the claude path"
else no "launcher baked in the claude path"; fi
if grep -qF -- '--work-dir "$WD"' "$PREFIX/bin/claude"; then ok "launcher passes a working directory"
else no "launcher passes a working directory"; fi

# --------------------------------------------------------------------------- #
# 3. the generated launcher must really exec proot-distro and forward arguments
# --------------------------------------------------------------------------- #
section "3. generated launcher"
out="$("$PREFIX/bin/claude" --version 2>&1)"; rc=$?
check "launcher exits 0" "$rc" "0"
check "launcher prints the container's claude version" "$out" "9.9.9-selftest (Claude Code)"
last_login="$(grep '^proot-distro login' "$CCT_LOG" | tail -1)"
if grep -qF -- '--work-dir' <<<"$last_login"; then ok "launcher passed --work-dir to proot-distro"
else no "launcher passed --work-dir to proot-distro (got: $last_login)"; fi
if grep -qF -- "-- $HOME/.local/bin/claude --version" <<<"$last_login"; then ok "launcher forwarded --version to claude"
else no "launcher forwarded --version to claude (got: $last_login)"; fi

# multiple arguments survive the trip
"$PREFIX/bin/claude" -p "hello world" >/dev/null 2>&1
last_login="$(grep '^proot-distro login' "$CCT_LOG" | tail -1)"
if grep -qF -- "-- $HOME/.local/bin/claude -p hello world" <<<"$last_login"; then ok "launcher forwarded multiple arguments"
else no "launcher forwarded multiple arguments (got: $last_login)"; fi

# --------------------------------------------------------------------------- #
# 4. re-running the installer must be idempotent
# --------------------------------------------------------------------------- #
section "4. idempotency"
out="$(bash "$INSTALL_SH" --force --yes --with-tmux 2>&1)"; rc=$?
if [ "$rc" != 0 ]; then printf '%s\n' "$out" | sed 's/^/    | /'; fi
check "second install exits 0" "$rc" "0"
if grep -q "already installed" <<<"$out"; then ok "second install reused the existing container"
else no "second install reused the existing container"; fi
assert_file "$PREFIX/bin/claude-tmux" "--with-tmux wrote the tmux helper"

# --------------------------------------------------------------------------- #
# 5. a broken container must surface as an error, not a silent success
# --------------------------------------------------------------------------- #
section "5. failure path"
mv "$CCT_STATE/ubuntu" "$CCT_STATE/ubuntu.bak"
"$PREFIX/bin/claude" --version >/dev/null 2>&1; rc=$?
if [ "$rc" != 0 ]; then ok "launcher fails when the container is gone (exit $rc)"
else no "launcher fails when the container is gone"; fi
mv "$CCT_STATE/ubuntu.bak" "$CCT_STATE/ubuntu"

# --------------------------------------------------------------------------- #
# 6. doctor.sh
# --------------------------------------------------------------------------- #
section "6. doctor.sh"
out="$(bash "$DOCTOR_SH" 2>&1)"; rc=$?
check "doctor exits 0 on a healthy install" "$rc" "0"
if grep -qF '9.9.9-selftest' <<<"$out"; then ok "doctor reported the claude version"
else no "doctor reported the claude version"; fi
if grep -qF '[fail]' <<<"$out"; then no "doctor reported no failures (output below)"; printf '%s\n' "$out" | sed 's/^/    | /'
else ok "doctor reported no failures"; fi

printf '\n%s\n' "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
