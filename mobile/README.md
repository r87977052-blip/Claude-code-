# Running Claude Code on an OPPO A3 5G (Android)

This directory turns your phone into a machine that runs the real Claude Code CLI.
Everything runs on the device — no PC, no root, no cloud VM.

```
bash mobile/install.sh      # in Termux, ~10 min, ~2 GB of storage
claude                      # then this just works
```

---

## 1. Your device

The OPPO A3 5G (CPH2683, launched in India 2024-08-19) is capable of this:

| | |
|---|---|
| SoC | MediaTek Dimensity 6300 — 2× Cortex-A76 @2.4 GHz + 6× Cortex-A55 @2.0 GHz |
| Architecture | 64-bit ARM → `uname -m` reports `aarch64` ✅ |
| RAM | 6 GB LPDDR4X |
| Storage | 128 GB (this setup needs ~3 GB free) |
| OS | Android 14 / ColorOS 14 |

(The Chinese-market A3 5G, model PKA110, uses a Snapdragon 695 instead. It is also
`aarch64` on Android 14, so everything below applies unchanged.)

What to expect on this hardware: Claude Code runs fine, but it is a ~245 MB native
binary running inside a proot-translated Ubuntu, so file-heavy operations
(grepping a big repo) feel slower than on a laptop. Chatting, editing files, git
work and small-to-medium projects are comfortable.

## 2. Why it needs a script

Claude Code 2.x is not a Node package any more — it is a prebuilt native binary,
one per platform. Verified against the published npm package `2.1.288`
(`latest` on 2026-10-03):

```
optionalDependencies:
  darwin-arm64, darwin-x64, linux-x64, linux-arm64,
  linux-x64-musl, linux-arm64-musl, win32-x64, win32-arm64
engines: node >=22.0.0
```

There is no Android build:

```
$ npm view @anthropic-ai/claude-code-linux-arm64-android version
npm error 404 Not Found - GET .../claude-code-linux-arm64-android - Not found
```

The launcher code already knows about Android (`cli-wrapper.cjs` and `install.cjs`
both map `process.platform === 'android'` to `linux-<arch>-android`), but no binary
is published for it, so on a phone the wrapper prints exactly this and stops:

```
[@anthropic-ai/claude-code] Native binaries for linux-arm64-android are not
available on this release channel.
  Available: darwin-arm64, darwin-x64, linux-x64, linux-arm64, linux-x64-musl,
  linux-arm64-musl, win32-x64, win32-arm64
```

And you cannot just run the Linux binary directly, because it needs glibc and
Android ships Bionic:

```
$ readelf -dW claude            # @anthropic-ai/claude-code-linux-arm64 2.1.288
  NEEDED  libc.so.6 / librt.so.1 / libpthread.so.0 / libdl.so.2 / libm.so.6
  INTERP  /lib/ld-linux-aarch64.so.1        (245,096,440 bytes)

$ readelf -lW claude            # the -musl build is not static either
  INTERP  /lib/ld-musl-aarch64.so.1
```

So the fix is to give Claude Code a real glibc userland on the phone. That is what
`install.sh` does: Termux → proot-distro → Ubuntu → Anthropic's own installer.
From Claude Code's point of view it is running on ordinary Ubuntu Linux.

## 3. Install

### 3.1 Get Termux

Install Termux **from F-Droid or the Termux GitHub releases**, not from Google Play —
the Play Store build is an unofficial fork the Termux maintainers do not support.

* F-Droid: <https://f-droid.org/en/packages/com.termux/>
* GitHub: <https://github.com/termux/termux-app/releases>

If you already have the Play Store build, uninstall it first (the two are signed
with different keys, so it cannot be updated in place).

### 3.2 Get this directory onto the phone

Easiest path — open Termux and clone the repo:

```bash
pkg update -y && pkg install -y git
git clone -b arena/01a100f1-claude-code https://github.com/r87977052-blip/Claude-code-.git
cd Claude-code-
```

(`mobile/` lives on the `arena/01a100f1-claude-code` branch, hence the `-b`.)

Or copy just `mobile/install.sh` to the phone — it is self-contained — and run
`bash install.sh`. To put it on the phone without git: upload it to Google Drive
and `termux-setup-storage` once, then `cp /sdcard/Download/install.sh ~`.

### 3.3 Run the installer

```bash
bash mobile/install.sh --check     # optional: preflight report only, installs nothing
bash mobile/install.sh             # the real thing
```

On Wi-Fi this takes roughly 10 minutes and about 2 GB. It will:

1. check the phone (Termux, `aarch64`, Android ≥ 8, ≥ 3 GB free, RAM, network);
2. `pkg install proot-distro curl git ca-certificates`;
3. create an Ubuntu container (`proot-distro install ubuntu`) — proot-distro 5.x
   pulls the image from Docker Hub, so `registry-1.docker.io` must be reachable;
4. inside Ubuntu: `apt-get install ca-certificates curl git tar xz-utils less`,
   then `curl -fsSL https://claude.ai/install.sh | bash`;
5. write a launcher at `$PREFIX/bin/claude` that enters the container in your
   current directory and runs Claude Code there;
6. verify with `claude --version`.

Useful flags:

| Flag | Effect |
|---|---|
| `--check` | Preflight only, installs nothing |
| `--with-tmux` | Also installs tmux + a `claude-tmux` helper (sessions survive screen-off) |
| `--distro NAME` | Use a different container (default `ubuntu`) |
| `--skip-packages` | Skip the `pkg` steps (packages already present) |
| `--force` | Ignore the Termux/aarch64 checks (other Linux-on-Android apps, CI) |

### 3.4 First run and sign-in

```bash
claude
```

Then type `/login` (or run `claude auth login`). Termux prints a
`https://claude.ai/...` URL — open it in the phone's browser and approve. The
browser is redirected to a `localhost` page that hands the token back to Claude
Code; the container shares the phone's network stack, so this works on-device.
If the browser handoff misbehaves, `claude setup-token` mints a long-lived token
instead, or set `ANTHROPIC_API_KEY` in `~/.bashrc`.

You need a paid Claude plan (Pro / Max / Team / Enterprise) or a Console API key.
The free plan does not include Claude Code.

## 4. Keep it alive on ColorOS

Android 14 aggressively kills background work. Do all three:

1. **Wake lock** (per session):
   ```bash
   termux-wake-lock          # needs Termux:API: pkg install termux-api
   ```
2. **Battery settings** — Settings → Apps → Termux → Battery usage → *Allow
   background activity*; then open Recent apps, pull the Termux card down and tap
   the lock icon so ColorOS does not swipe it away. Turn off
   Settings → Battery → *Sleep* / *Deep sleep* for Termux.
3. **Phantom process killer** (Android 12+). If long sessions die with
   `Process completed (signal 9)`, disable it. This needs a computer with `adb`
   (Developer options → USB debugging) once:
   ```bash
   adb shell "settings put global settings_enable_monitor_phantom_procs false"
   # Android 12 additionally needs:
   adb shell "/system/bin/device_config set_sync_disabled_for_tests persistent"
   adb shell "/system/bin/device_config put activity_manager max_phantom_processes 2147483647"
   ```
   On Android ≥ 14 this setting reverts if you turn Developer options off — leave
   them on. `bash mobile/doctor.sh` reports the current value.

## 5. Using it comfortably

* **Working directory.** Any path under `$HOME` or `/storage` is visible inside the
  container *at the same path* (proot-distro binds the Termux home and shared
  storage), so `cd ~/my-project && claude` just works. Anything else (e.g.
  `$PREFIX`) falls back to `$HOME`.
* **Shared storage.** Run `termux-setup-storage` once to grant file access, then
  `cd /sdcard/...`.
* **Keyboard.** Claude Code wants ESC, TAB, CTRL and the arrows:
  ```bash
  mkdir -p ~/.termux
  echo "extra-keys = [['ESC','/','-','HOME','UP','END'],['TAB','CTRL','ALT','LEFT','DOWN','RIGHT']]" >> ~/.termux/termux.properties
  termux-reload-settings
  ```
  A Bluetooth or USB-C keyboard makes a real difference on a 6.67″ 720p screen.
* **Survive screen-off:** `bash mobile/install.sh --with-tmux` then `claude-tmux`.
* **Health check:** `bash mobile/doctor.sh` (add `--deep` to also run
  `claude doctor` inside the container).
* **Update:** `claude update` — or re-run `bash mobile/install.sh`.
* **Uninstall:** `rm $PREFIX/bin/claude` and `proot-distro remove ubuntu`.

## 6. Troubleshooting

| Symptom | Cause / fix |
|---|---|
| `Unsupported platform: android arm64` or `Native binaries for linux-arm64-android are not available` | You installed the npm package in Termux. Use `mobile/install.sh` instead; `npm i -g @anthropic-ai/claude-code` cannot work on Android. |
| `uname -m` says `armv7l` | 32-bit userland — Claude Code has no build for it. Not fixable. |
| `proot-distro install ubuntu` fails | Docker Hub unreachable (mobile-data DNS, captive portal, VPN). Retry on Wi-Fi, or install from a rootfs URL. |
| `Error: container 'ubuntu' is not installed.` | `proot-distro install ubuntu`, then re-run the installer. |
| Installer downloads but `claude` is not found | Run `proot-distro login ubuntu` and `bash /tmp/claude-install.sh` by hand to see the installer's own error. |
| `Process completed (signal 9)` | Phantom process killer / ColorOS — see section 4. |
| Everything is slow | proot translates syscalls in userspace. Keep the project small, avoid huge `node_modules`, and close other apps (6 GB RAM is shared with the container). |
| Login loop / browser never returns | Use `claude setup-token`, or `export ANTHROPIC_API_KEY=...`. |

## 7. Alternatives

* **Lighter on-device shim (~230 MB instead of ~2 GB).** The community project
  [`ferrumclaudepilgrim/claude-code-android`](https://github.com/ferrumclaudepilgrim/claude-code-android)
  patches Anthropic's `linux-arm64` binary to load through Termux's `glibc-runner`,
  with an auto-updating wrapper. It works, but it is a compatibility shim over an
  unsupported configuration: sandbox and filesystem behaviour is not always what
  Claude Code expects. Upstream tracking issue: `anthropics/claude-code#50270`.
* **Phone as a terminal.** If you have an always-on computer, install Claude Code
  there and connect from the phone (`pkg install openssh`, then `ssh` + `tmux`,
  optionally over Tailscale). Faster and more robust; the phone is only a display.

## 8. What was verified, and what was not

Verified on 2026-10-03 (commands and outputs reproduced above):

* Claude Code `2.1.288` platform matrix, `engines.node >=22`, and the missing
  Android binary package (npm 404) — from the published package itself.
* The `linux-arm64-android` code path in the shipped `cli-wrapper.cjs` /
  `install.cjs`, executed with `process.platform` spoofed to `android`.
* ELF linkage of both the `linux-arm64` and `linux-arm64-musl` binaries
  (`readelf -dW` / `-lW`).
* `proot-distro` 5.9.0 CLI and bind semantics — installed from PyPI and read from
  source (`--work-dir`, `--bind SRC:DEST`, `--shared-home`;
  `--bind={TERMUX_HOME}` at the same path for normal containers).
* Termux packages proot-distro **5.9.0** (`TERMUX_PKG_VERSION` in
  `termux-packages/packages/proot-distro/build.sh`).
* OPPO A3 5G hardware/OS specs.
* `mobile/install.sh`, `mobile/doctor.sh` and the launcher they generate:
  **31/31 assertions** in `bash mobile/tests/selftest.sh`, which runs the real
  installer end to end against stubbed `pkg` / `proot-distro` / `apt-get` / `curl`.

**Not** verified, because there is no Android device in this workspace and
`claude.ai` is not reachable from it: the actual download of Anthropic's installer,
the real Ubuntu image pull, and Claude Code's behaviour inside proot on a
Dimensity 6300. Run `bash mobile/doctor.sh` on the phone after installing — it
checks every layer and tells you which one broke.
