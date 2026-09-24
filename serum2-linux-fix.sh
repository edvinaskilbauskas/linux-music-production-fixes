#!/usr/bin/env bash
#
# serum2-linux-fix.sh
#
# Fix the Xfer Serum 2 GUI under Wine: the plugin editor renders garbled (or
# black) and only "snaps" back, or stays broken, after the window is moved,
# resized or hovered.
#
# WHY IT HAPPENS
#
#   Serum 2's editor is a VSTGUI window drawn through Direct2D, presented
#   through DirectComposition, with D3D11 underneath (the bundle imports
#   d2d1.dll, d3d11.dll, dwmapi.dll and friends). Stock Wine's D2D1 is a
#   partial implementation and its dcomp is a stub. The only stock-Wine
#   workaround is Serum's own "Disable DirectComposition" switch, which drops
#   the plugin to a plain GDI/HWND path - and in Wine that path leaves the
#   plugin's HWND as an offscreen-redirected X11 child window that wined3d's
#   GDI present never composites. Result: the editor is stale or scrambled
#   until something forces a repaint, i.e. exactly the "broken after moving
#   the window" symptom. No registry setting fixes it; the compositing has to
#   actually happen.
#
# THE FIX
#
#   giang17's Wine "d2d1-dcomp" patch series (base: wine-11.0) implements the
#   pieces this needs: the D2D1 geometry pipeline, DComp visual trees with a
#   DIB+BitBlt presentation path, the winex11 client-surface handling for
#   ID2D1HwndRenderTarget windows (so the plugin's X11 child is attached to
#   the host's toplevel instead of being offscreen-redirected), and the
#   wined3d GL present. Together they make Serum 2 render correctly and stay
#   correct across window moves and resizes.
#
#   That patch series is deep - it touches win32u, user32, ntdll, the wineserver,
#   wined3d, winex11.drv, d2d1, dcomp, dxgi and dwrite - so it cannot be shipped
#   as a handful of replacement DLLs; it has to be a full Wine build. This script
#   builds it into its own prefix and leaves your distro Wine alone.
#
#   Serum 2 is 64-bit (and so is FL Studio 2026), so a 64-bit-only Wine is built
#   by default; pass --both-archs if you also need to run 32-bit plugins.
#
#   The build lands in /opt/wine-d2d1 and FL Studio is launched with it through
#   ~/.local/bin/flstudio (plus an apps-menu entry). Your existing prefix is
#   reused as-is; see "NOTES" at the end for what that implies.
#
# Run as your NORMAL user (not root). The script calls sudo when needed.
#
# Usage:
#   ./serum2-linux-fix.sh [options]
#
#   --prefix PATH        install the patched Wine here (default /opt/wine-d2d1)
#   --jobs N             parallel build jobs (default: nproc)
#   --both-archs         build 32-bit + 64-bit (needs gcc-mingw-w64-i686)
#   --clean              delete the cached source tree before building
#   --force-build        rebuild even if a build of this branch is cached
#   --skip-deps          do not install build dependencies
#   --skip-build         do not configure/build/install Wine
#   --skip-prefix        do not update the Wine prefix
#   --skip-serum-config  do not touch Serum2Prefs.json
#   --skip-launcher      do not write the launcher / menu entry
#   --verify-only        only run the end-to-end checks
#   -h, --help           this help
#
# Re-running is safe: the build is cached and every step is idempotent and
# keeps backups.
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

FORK_URL="https://github.com/giang17/wine.git"
FORK_BRANCH="d2d1-dcomp-11.0"
FORK_BASE="wine-11.0"          # the branch is based on this Wine release
INSTALL_PREFIX="${WINE_D2D1_PREFIX:-/opt/wine-d2d1}"
BUILD_ROOT="${HOME}/wine-d2d1-build"
SRC="$BUILD_ROOT/wine"
LAUNCHER="${HOME}/.local/bin/flstudio"

BUILD_DEPS_COMMON="flex bison gcc-mingw-w64-x86-64 git make pkg-config \
ca-certificates curl libx11-dev libxcomposite-dev libxcursor-dev libxfixes-dev \
libxi-dev libxrandr-dev libxrender-dev libxext-dev libfreetype-dev \
libfontconfig-dev libgl-dev libegl-dev libasound2-dev libpulse-dev \
libdbus-1-dev libgnutls28-dev libunwind-dev libwayland-dev libwayland-bin \
libxkbcommon-dev libvulkan-dev libudev-dev libsdl2-dev"

JOBS="$(nproc 2>/dev/null || echo 4)"

DO_DEPS=1
DO_BUILD=1
DO_PREFIX=1
DO_SERUM=1
DO_LAUNCHER=1
BOTH_ARCHS=0
FORCE_BUILD=0
CLEAN=0
VERIFY_ONLY=0

# ---------------------------------------------------------------------------
# Output helpers
# ---------------------------------------------------------------------------

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'
else
    C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GRN=; C_YEL=; C_BLU=
fi

step()  { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLU" "$*" "$C_RESET"; }
info()  { printf '    %s\n' "$*"; }
ok()    { printf '    %s[ ok ]%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn()  { printf '    %s[warn]%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
die()   { printf '\n%s[fail]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

usage() { sed -n '3,64p' "$0" | sed 's/^# \{0,1\}//'; }

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --prefix)            INSTALL_PREFIX="${2:?--prefix needs a path}"; shift ;;
        --jobs)              JOBS="${2:?--jobs needs a number}"; shift ;;
        --both-archs)        BOTH_ARCHS=1 ;;
        --clean)             CLEAN=1 ;;
        --force-build)       FORCE_BUILD=1 ;;
        --skip-deps)         DO_DEPS=0 ;;
        --skip-build)        DO_BUILD=0 ;;
        --skip-prefix)       DO_PREFIX=0 ;;
        --skip-serum-config) DO_SERUM=0 ;;
        --skip-launcher)     DO_LAUNCHER=0 ;;
        --verify-only)       VERIFY_ONLY=1; DO_DEPS=0; DO_BUILD=0; DO_PREFIX=0
                             DO_SERUM=0; DO_LAUNCHER=0 ;;
        -h|--help)           usage; exit 0 ;;
        *)                   die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Privilege handling: never run the whole script as root (the build would leave
# root-owned files in ~/wine-d2d1-build). Call sudo per-operation instead.
# ---------------------------------------------------------------------------

if [ "$(id -u)" -eq 0 ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "${S2FIX_DROPPED:-0}" != "1" ]; then
        info "Running as root; re-executing as ${SUDO_USER} (you may be asked for a password again)."
        exec sudo -u "$SUDO_USER" -H env S2FIX_DROPPED=1 bash "$0" "$@"
    fi
    die "Do not run this script as root. Run it as your normal user; it will call sudo itself."
fi

HAS_SUDO=0
if command -v sudo >/dev/null 2>&1; then
    if sudo -v 2>/dev/null; then
        HAS_SUDO=1
        ( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null || exit; sleep 50; done ) &
        SUDO_KEEPALIVE_PID=$!
        trap 'kill "$SUDO_KEEPALIVE_PID" 2>/dev/null || true' EXIT
    fi
fi
[ "$HAS_SUDO" -eq 1 ] || warn "sudo unavailable - steps that need root will be skipped."

root_run() {
    if [ "$HAS_SUDO" -eq 1 ]; then sudo "$@"; else "$@"; fi
}

# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

printf '%sSerum 2 / Wine GUI fix%s  (install %s)\n' "$C_BOLD" "$C_RESET" "$INSTALL_PREFIX"

step "Detecting environment"

WINE_BIN="$(command -v wine || true)"
[ -n "$WINE_BIN" ] || die "wine not found in PATH."
WINE_REAL="$(readlink -f "$WINE_BIN")"
WINE_ROOT="$(dirname "$(dirname "$WINE_REAL")")"
WINE_VERSION="$(wine --version 2>/dev/null | sed 's/^wine-//')"

# Where the *system* Wine keeps its builtins. Used to tell a Wine-generated
# "fake" DLL in the prefix apart from one an installer put there (native).
SYS_WINE_LIB=""
for cand in "$WINE_ROOT/lib/wine" "$WINE_ROOT/lib64/wine" \
            /usr/lib/wine /usr/lib/x86_64-linux-gnu/wine /usr/lib64/wine; do
    if [ -d "$cand/x86_64-windows" ]; then SYS_WINE_LIB="$cand"; break; fi
done
[ -n "$SYS_WINE_LIB" ] || warn "Could not locate the system Wine's builtin DLL directory."

export WINEPREFIX="${WINEPREFIX:-$HOME/.wine}"
[ -d "$WINEPREFIX/drive_c" ] || die "Wine prefix not found at $WINEPREFIX"
PREFIX_SYSDIR="$WINEPREFIX/drive_c/windows/system32"

# FL Studio install directory, located by its main executable so that
# unrelated siblings such as "FL Studio ASIO" are not mistaken for the app.
FL_DIR="$(find "$WINEPREFIX/drive_c/Program Files/Image-Line" -maxdepth 2 \
              -name FL64.exe -printf '%h\n' 2>/dev/null | sort -V | tail -1 || true)"

# Serum 2's settings file (it holds the DirectComposition switches).
SERUM_PREFS="$(find "$WINEPREFIX/drive_c/users" -maxdepth 6 \
                   -name Serum2Prefs.json -print -quit 2>/dev/null || true)"

info "system wine    : $WINE_VERSION ($WINE_ROOT)"
info "wine prefix    : $WINEPREFIX"
info "install prefix : $INSTALL_PREFIX"
info "build cache    : $BUILD_ROOT"
if [ -n "$FL_DIR" ]; then info "FL Studio      : $(basename "$FL_DIR")"
else warn "FL Studio install directory not found under $WINEPREFIX"; fi
if [ -n "$SERUM_PREFS" ]; then info "Serum 2 config : $SERUM_PREFS"
else warn "Serum2Prefs.json not found (is Serum 2 installed?)"; fi

FORK_BASE_VERSION="${FORK_BASE#wine-}"
case "$WINE_VERSION" in
    "$FORK_BASE_VERSION"*) ok "system Wine matches the patch series' base ($FORK_BASE)" ;;
    *) warn "system Wine is $WINE_VERSION but the patch series is based on $FORK_BASE."
       warn "The patched Wine is installed separately and is self-contained, so this"
       warn "only matters for the shared prefix and WineASIO (see NOTES)." ;;
esac

# ---------------------------------------------------------------------------
# Step 1 - build dependencies
# ---------------------------------------------------------------------------

have_all_deps() {
    local t
    for t in flex bison make pkg-config git curl x86_64-w64-mingw32-gcc; do
        command -v "$t" >/dev/null 2>&1 || return 1
    done
    pkg-config --exists x11 xcomposite freetype2 fontconfig gl egl 2>/dev/null || return 1
    return 0
}

install_deps() {
    step "Step 1/7  Build dependencies"

    if [ "$HAS_SUDO" -ne 1 ]; then
        warn "sudo unavailable; cannot install build dependencies."
        have_all_deps || die "Build dependencies are missing and cannot be installed.
    Re-run with sudo available, or install them manually:
    sudo apt install $BUILD_DEPS_COMMON"
        return 0
    fi

    local pkgs="$BUILD_DEPS_COMMON"
    if [ "$BOTH_ARCHS" -eq 1 ]; then pkgs="$pkgs gcc-mingw-w64-i686"; fi

    if have_all_deps; then
        ok "build tools and dev libraries already present"
    else
        info "Installing build dependencies (this pulls in the X11/GL/font dev packages)..."
        # shellcheck disable=SC2086
        if ! root_run apt-get install -y --no-install-recommends $pkgs; then
            # One unknown package name makes apt refuse the whole transaction, so
            # retry individually and let the good ones through.
            warn "bulk install failed; retrying package by package"
            local p
            for p in $pkgs; do
                root_run apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 \
                    || warn "could not install $p"
            done
        fi
    fi

    local missing=0 t
    for t in flex bison make pkg-config git curl x86_64-w64-mingw32-gcc; do
        command -v "$t" >/dev/null 2>&1 || { warn "missing build tool: $t"; missing=1; }
    done
    [ "$missing" -eq 0 ] || die "Build tools are missing. Install them with:
    sudo apt install $pkgs"

    # libxcomposite is not optional for this fix: it is what lets Wine attach a
    # D2D1 HwndRenderTarget window's X11 child to the host's toplevel instead of
    # leaving it offscreen-redirected (the garbled-until-moved symptom).
    if pkg-config --exists xcomposite 2>/dev/null; then
        ok "libxcomposite present (needed for the offscreen-window fix)"
    else
        die "libxcomposite-dev is missing. Without it Wine builds without the XComposite
    support that fixes the plugin window, so the build would be pointless.
    Install it:  sudo apt install libxcomposite-dev"
    fi
}

# ---------------------------------------------------------------------------
# Step 2 - fetch the patched Wine sources
# ---------------------------------------------------------------------------

fetch_source() {
    step "Step 2/7  Fetching the patched Wine sources"

    mkdir -p "$BUILD_ROOT"

    if [ "$CLEAN" -eq 1 ] && [ -d "$SRC" ]; then
        info "Removing cached source tree (--clean)"
        rm -rf "$SRC"
    fi

    if [ -d "$SRC/.git" ]; then
        local cur
        cur="$(git -C "$SRC" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?')"
        if [ "$cur" = "$FORK_BRANCH" ]; then
            ok "reusing cached $FORK_BRANCH tree at $SRC"
        else
            info "cached tree is on '$cur'; re-cloning $FORK_BRANCH"
            rm -rf "$SRC"
        fi
    fi

    if [ ! -d "$SRC/.git" ]; then
        info "Cloning $FORK_URL ($FORK_BRANCH, shallow)..."
        git clone --depth 1 --branch "$FORK_BRANCH" "$FORK_URL" "$SRC" \
            || die "git clone failed. Check your network connection."
    fi

    [ -f "$SRC/configure.ac" ] || die "Source tree at $SRC does not look like Wine."
    local head; head="$(git -C "$SRC" log --oneline -1 2>/dev/null || true)"
    ok "source ready: $head"
}

# ---------------------------------------------------------------------------
# Step 3 - configure, build and install the patched Wine
# ---------------------------------------------------------------------------

BUILD_STAMP() {
    local archs="x86_64"
    [ "$BOTH_ARCHS" -eq 1 ] && archs="i386,x86_64"
    echo "$BUILD_ROOT/.built-${FORK_BRANCH}-${archs//,/_}"
}

ARCHS_ARG() {
    if [ "$BOTH_ARCHS" -eq 1 ]; then echo "i386,x86_64"; else echo "x86_64"; fi
}

build_wine() {
    step "Step 3/7  Building the patched Wine (this takes a while)"

    if [ "$HAS_SUDO" -ne 1 ]; then
        die "Installing Wine into $INSTALL_PREFIX requires root. Re-run with sudo available."
    fi

    local archs stamp built
    archs="$(ARCHS_ARG)"
    stamp="$(BUILD_STAMP)"
    built="$SRC/dlls/d2d1/x86_64-windows/d2d1.dll"

    if [ "$BOTH_ARCHS" -eq 1 ] && ! command -v i686-w64-mingw32-gcc >/dev/null 2>&1; then
        die "i686-w64-mingw32-gcc is required for --both-archs.
    sudo apt install gcc-mingw-w64-i686"
    fi

    if [ "$FORCE_BUILD" -eq 0 ] && [ -f "$stamp" ] && [ -f "$built" ] && [ -x "$INSTALL_PREFIX/bin/wine" ]; then
        ok "patched Wine already built and installed (skipping; use --force-build to redo)"
        return 0
    fi

    cd "$SRC"
    if [ -f "$SRC/config.status" ] && [ -f "$SRC/Makefile" ]; then
        ok "source tree already configured (reusing)"
    else
        info "Configuring Wine for --enable-archs=$archs --prefix=$INSTALL_PREFIX ..."
        ./configure --prefix="$INSTALL_PREFIX" --enable-archs="$archs" --disable-tests \
            >"$BUILD_ROOT/configure.log" 2>&1 \
            || die "configure failed - see $BUILD_ROOT/configure.log"
        ok "configured"
    fi

    # XComposite must have been detected, or the fix is not in the build.
    if ! grep -q '^HAVE_XCOMPOSITE' "$SRC/include/config.h" 2>/dev/null; then
        warn "configure did not detect XComposite - the offscreen-window fix will be missing."
        warn "Install libxcomposite-dev, then re-run with --clean --force-build."
    fi

    info "Compiling Wine with $JOBS jobs (this is the long part)..."
    make -j"$JOBS" >"$BUILD_ROOT/build.log" 2>&1 \
        || die "build failed - see $BUILD_ROOT/build.log"

    [ -f "$built" ] || die "build produced no d2d1.dll"

    info "Installing into $INSTALL_PREFIX ..."
    root_run make install >"$BUILD_ROOT/install.log" 2>&1 \
        || die "make install failed - see $BUILD_ROOT/install.log"

    [ -x "$INSTALL_PREFIX/bin/wine" ] || die "no wine binary in $INSTALL_PREFIX after install"
    : > "$stamp"
    ok "installed patched Wine: $("$INSTALL_PREFIX/bin/wine" --version 2>/dev/null)"
}

# ---------------------------------------------------------------------------
# Step 4 - point the existing prefix at the patched Wine
# ---------------------------------------------------------------------------
#
# Wine copies every builtin PE into the prefix's system32 and the loader reads
# them from there, so a freshly installed Wine is *not* picked up by an existing
# prefix on its own. `wineboot -u` re-runs wine.inf, whose [FakeDllsWin64]
# wildcard rewrites each of those copies from the installation - which is what
# makes the new (patched) d2d1/dcomp/dxgi/wined3d/winex11 code take effect.

refresh_prefix() {
    step "Step 4/7  Updating the Wine prefix"

    if pgrep -x FL64.exe >/dev/null 2>&1; then
        die "FL Studio is running. Close it and re-run this script."
    fi

    local new_wine="$INSTALL_PREFIX/bin/wine"
    [ -x "$new_wine" ] || { warn "patched Wine not installed; skipping."; return 0; }

    info "Running wineboot -u with the patched Wine (a progress window may flash)..."
    WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all timeout 600 "$new_wine" wineboot -u \
        >"$BUILD_ROOT/wineboot.log" 2>&1 \
        || warn "wineboot returned non-zero - see $BUILD_ROOT/wineboot.log"

    # Deterministic registry defaults the branch's wine.inf carries. The branch's
    # wine.inf sets these with the no-clobber flag; setting them explicitly makes
    # the result independent of whether wine.inf happened to re-run.
    local key='HKCU\Software\Wine\AppDefaults\FL64.exe'
    WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all timeout 60 "$new_wine" reg add \
        "$key" /v HideWineVersion /t REG_SZ /d Y /f >/dev/null 2>&1 \
        && ok "FL64.exe: HideWineVersion=Y (lets D2D-based plugin UIs use D2D)" \
        || warn "could not set HideWineVersion for FL64.exe"

    sync_prefix_dlls
}

# Verify that the prefix actually received the patched DLLs, and repair the
# handful this fix depends on if wineboot did not. A prefix DLL is only
# overwritten when it is a Wine-generated "fake" (byte-identical to some Wine
# installation's builtin) - never when an installer put a native DLL there.
sync_prefix_dlls() {
    local dlls="d2d1 dcomp dxgi d3d11 dwrite wined3d win32u user32 gdi32 ntdll"
    local d patched old src dst fixed=0 checked=0

    patched="$INSTALL_PREFIX/lib/wine/x86_64-windows"
    old="${SYS_WINE_LIB:+$SYS_WINE_LIB/x86_64-windows}"

    for d in $dlls; do
        src="$patched/$d.dll"; dst="$PREFIX_SYSDIR/$d.dll"
        [ -f "$src" ] || continue
        checked=$((checked + 1))
        if [ -f "$dst" ] && cmp -s "$src" "$dst"; then continue; fi

        # Only replace a file that is clearly a Wine fake: absent, or identical
        # to the *system* Wine's copy of the same DLL.
        if [ -f "$dst" ]; then
            if [ -n "$old" ] && [ -f "$old/$d.dll" ] && cmp -s "$dst" "$old/$d.dll"; then
                :
            else
                warn "$d.dll in the prefix is not a Wine fake - leaving it alone"
                continue
            fi
            [ -f "$dst.orig" ] || cp -f "$dst" "$dst.orig"
        fi
        cp -f "$src" "$dst" && fixed=$((fixed + 1))
    done

    # Report on a sentinel: d2d1 is the one the whole fix hinges on.
    if [ -f "$PREFIX_SYSDIR/d2d1.dll" ] && cmp -s "$patched/d2d1.dll" "$PREFIX_SYSDIR/d2d1.dll"; then
        if [ "$fixed" -gt 0 ]; then
            ok "prefix updated with the patched DLLs ($fixed of $checked refreshed)"
        else
            ok "prefix already uses the patched DLLs"
        fi
    else
        warn "prefix still has an unpatched d2d1.dll - the GUI fix will not take effect."
        warn "Run:  WINEPREFIX=$WINEPREFIX $INSTALL_PREFIX/bin/wineboot -u"
    fi
}

# ---------------------------------------------------------------------------
# Step 5 - WineASIO in the patched Wine
# ---------------------------------------------------------------------------
#
# WineASIO is a Wine unix-lib module, not a normal DLL: it is built against the
# Wine headers and dlopen'd from an absolute path recorded in the CLSID. The
# copy already built for the system Wine (same release) is ABI-compatible with
# this build, so it is copied over and the CLSID is re-pointed.

WINEASIO_CLSID="{48D0C522-BFCC-45CC-8B84-17F25F33E6E8}"

install_wineasio() {
    step "Step 5/7  WineASIO (low-latency ASIO) in the patched Wine"

    local src_so src_dll
    src_so="$(ls "$WINE_ROOT"/lib*/wine/x86_64-unix/wineasio64.so 2>/dev/null | head -1 || true)"
    src_dll="$(ls "$WINE_ROOT"/lib*/wine/x86_64-windows/wineasio64.dll 2>/dev/null | head -1 || true)"

    if [ -z "$src_so" ] || [ -z "$src_dll" ]; then
        warn "no WineASIO found in $WINE_ROOT - skipping."
        warn "Run fl-studio-linux-fix.sh first if you want ASIO with the patched Wine."
        return 0
    fi

    local dst_so="$INSTALL_PREFIX/lib/wine/x86_64-unix/wineasio64.so"
    local dst_dll="$INSTALL_PREFIX/lib/wine/x86_64-windows/wineasio64.dll"
    [ -d "$(dirname "$dst_so")" ] || { warn "patched Wine not installed; skipping."; return 0; }

    root_run install -m 644 "$src_dll" "$dst_dll"
    root_run install -m 755 "$src_so" "$dst_so"
    ok "copied WineASIO into $INSTALL_PREFIX"

    # Re-point the CLSID at the copy inside the patched tree.
    local so_win
    so_win="Z:$(printf '%s' "$dst_so" | sed 's|/|\\|g')"
    WINEPREFIX="$WINEPREFIX" WINEDEBUG=-all timeout 60 "$INSTALL_PREFIX/bin/wine" reg add \
        "HKCU\\Software\\Classes\\CLSID\\$WINEASIO_CLSID\\InProcServer32" /ve /d "$so_win" /f \
        >/dev/null 2>&1 \
        && ok "CLSID $WINEASIO_CLSID -> $so_win" \
        || warn "could not re-point the WineASIO CLSID (ASIO may not appear in FL)"
}

# ---------------------------------------------------------------------------
# Step 6 - Serum 2 settings
# ---------------------------------------------------------------------------
#
# With the patched dcomp in place, Serum's DirectComposition path is the one to
# use: it is faster and it is the path the series was developed against. The GDI
# fallback (DirectComposition disabled) is supported too, but there is no reason
# to give up the performance once DComp actually works.

configure_serum() {
    step "Step 6/7  Serum 2 settings"

    if [ -z "$SERUM_PREFS" ]; then
        warn "Serum2Prefs.json not found; skipping."
        return 0
    fi
    if pgrep -x FL64.exe >/dev/null 2>&1; then
        warn "FL Studio is running; it rewrites this file on exit."
        warn "Close FL Studio and re-run to apply the Serum settings."
        return 0
    fi

    local cur_dc cur_pr
    cur_dc="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("Disable DirectComposition"))' "$SERUM_PREFS" 2>/dev/null || echo '?')"
    cur_pr="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("Disable Partial Redraw"))' "$SERUM_PREFS" 2>/dev/null || echo '?')"

    if [ "$cur_dc" = "False" ] && [ "$cur_pr" = "False" ]; then
        ok "Serum already uses DirectComposition (Disable DirectComposition=false)"
        return 0
    fi

    [ -f "$SERUM_PREFS.bak" ] || cp -f "$SERUM_PREFS" "$SERUM_PREFS.bak"

    # Edit in place rather than parse-and-rewrite: Serum writes this file with
    # no indentation, and a re-dump would reformat every line.
    python3 - "$SERUM_PREFS" <<'PY'
import json, re, sys
path = sys.argv[1]
keys = ("Disable DirectComposition", "Disable Partial Redraw")
with open(path) as fh:
    text = fh.read()

changed = False
for key in keys:
    text, n = re.subn(r'("%s"\s*:\s*)true' % re.escape(key), r'\1false', text)
    changed = changed or bool(n)

if not changed:  # a key is missing or spelled differently; fall back to a rewrite
    prefs = json.loads(text)
    for key in keys:
        prefs[key] = False
    text = json.dumps(prefs, indent=0)

json.loads(text)  # refuse to write something unparseable
with open(path, "w") as fh:
    fh.write(text)
PY

    ok "enabled DirectComposition in Serum 2 (backup: $(basename "$SERUM_PREFS").bak)"
    info "was: Disable DirectComposition=$cur_dc, Disable Partial Redraw=$cur_pr"
}

# ---------------------------------------------------------------------------
# Step 7 - launcher and apps-menu entry
# ---------------------------------------------------------------------------

install_launcher() {
    step "Step 7/7  Launcher"

    if [ -z "$FL_DIR" ]; then
        warn "FL Studio not found; skipping launcher."
        return 0
    fi

    mkdir -p "$(dirname "$LAUNCHER")"
    cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# Launch FL Studio 2026 with the patched Wine (giang17 d2d1-dcomp), which is what
# makes Serum 2's Direct2D/DirectComposition editor render correctly.
set -euo pipefail
export WINEPREFIX="\${WINEPREFIX:-$WINEPREFIX}"
WINE="$INSTALL_PREFIX/bin/wine"
FL_DIR="$FL_DIR"
[ -x "\$WINE" ] || { echo "patched Wine missing at \$WINE; run serum2-linux-fix.sh" >&2; exit 1; }
cd "\$FL_DIR"
exec "\$WINE" FL64.exe "\$@"
EOF
    chmod +x "$LAUNCHER"
    ok "launcher: $LAUNCHER"

    case ":$PATH:" in
        *":$(dirname "$LAUNCHER"):"*) ;;
        *) warn "$(dirname "$LAUNCHER") is not in PATH - call it by full path" ;;
    esac

    local apps="$HOME/.local/share/applications"
    mkdir -p "$apps"
    cat > "$apps/fl-studio-2026-d2d1.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=FL Studio 2026 (patched Wine)
GenericName=Digital Audio Workstation
Comment=FL Studio with the Wine build that fixes Serum 2's GUI
Exec=$LAUNCHER
Path=$FL_DIR
Icon=1010_FL64.0
Terminal=false
Categories=AudioVideo;Audio;Music;
Keywords=flstudio;daw;audio;music;vst;
StartupWMClass=fl64.exe
StartupNotify=true
EOF
    chmod +x "$apps/fl-studio-2026-d2d1.desktop"
    ok "menu entry: $apps/fl-studio-2026-d2d1.desktop"

    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "$apps" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

verify() {
    step "Verification"

    local bad=0

    if [ -x "$INSTALL_PREFIX/bin/wine" ]; then
        ok "patched Wine installed: $("$INSTALL_PREFIX/bin/wine" --version 2>/dev/null)"
    else
        warn "patched Wine not installed at $INSTALL_PREFIX"; bad=1
    fi

    # The patched d2d1 must differ from the distro Wine's (the series rewrites it).
    if [ -n "$SYS_WINE_LIB" ] && [ -f "$INSTALL_PREFIX/lib/wine/x86_64-windows/d2d1.dll" ]; then
        if cmp -s "$INSTALL_PREFIX/lib/wine/x86_64-windows/d2d1.dll" "$SYS_WINE_LIB/x86_64-windows/d2d1.dll"; then
            warn "installed d2d1.dll is identical to the distro Wine's - the patches are not in it"; bad=1
        else
            ok "installed d2d1.dll is the patched one"
        fi
    fi

    # The prefix is what the loader actually reads from.
    if [ -f "$PREFIX_SYSDIR/d2d1.dll" ] && [ -f "$INSTALL_PREFIX/lib/wine/x86_64-windows/d2d1.dll" ]; then
        if cmp -s "$PREFIX_SYSDIR/d2d1.dll" "$INSTALL_PREFIX/lib/wine/x86_64-windows/d2d1.dll"; then
            ok "prefix uses the patched d2d1.dll"
        else
            warn "prefix still has an unpatched d2d1.dll (run wineboot -u with the patched Wine)"; bad=1
        fi
    fi

    if [ -f "$INSTALL_PREFIX/lib/wine/x86_64-unix/wineasio64.so" ]; then
        ok "WineASIO present in the patched Wine"
    else
        warn "WineASIO not in the patched Wine (FL will fall back to FL Studio ASIO)"; bad=1
    fi

    if [ -n "$SERUM_PREFS" ]; then
        if python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); sys.exit(0 if d.get("Disable DirectComposition") is False else 1)' \
                "$SERUM_PREFS" 2>/dev/null; then
            ok "Serum 2 is set to use DirectComposition"
        else
            warn "Serum 2 still has DirectComposition disabled"; bad=1
        fi
    fi

    [ -x "$LAUNCHER" ] && ok "launcher: $LAUNCHER" || { warn "no launcher"; bad=1; }

    printf '\n'
    if [ "$bad" -eq 0 ]; then
        printf '%sReady.%s Launch FL Studio with: %s\n' "$C_BOLD$C_GRN" "$C_RESET" "$LAUNCHER"
        printf 'Open Serum 2 and drag its window around - it should stay clean.\n'
    else
        printf '%sSome checks failed - see warnings above.%s\n' "$C_BOLD$C_YEL" "$C_RESET"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

if [ "$VERIFY_ONLY" -eq 0 ]; then
    if [ "$DO_DEPS"   -eq 1 ]; then install_deps; fi
    if [ "$DO_BUILD"  -eq 1 ]; then fetch_source; build_wine; fi
    if [ "$DO_PREFIX" -eq 1 ]; then refresh_prefix; fi
    if [ "$DO_BUILD"  -eq 1 ]; then install_wineasio; fi
    if [ "$DO_SERUM"  -eq 1 ]; then configure_serum; fi
    if [ "$DO_LAUNCHER" -eq 1 ]; then install_launcher; fi
fi

verify

cat <<EOF

${C_DIM}NOTES / how to undo${C_RESET}

  * Why a separate Wine: the patch series changes win32u, user32, ntdll, the
    wineserver, wined3d and winex11, so it cannot be a few dropped-in DLLs.
    Your distro Wine at $WINE_ROOT is untouched.

  * Shared prefix: FL Studio keeps using $WINEPREFIX, but its builtin DLLs
    are refreshed from the patched Wine. Because a prefix holds one set of
    builtins, running FL with the *distro* Wine afterwards would keep loading
    the patched DLLs (they are the same Wine release, so that is harmless, but
    if you want the stock Wine back for other apps, give those apps their own
    prefix:  WINEPREFIX=~/.wine-stock wine ...).

  * DXVK: do not install DXVK into this prefix. The branch's DComp and
    composition-swapchain handling live in Wine's dxgi/d3d11, which DXVK
    replaces; mixing them is unsupported. WineD3D is what Serum 2 wants here.

  * Undo the Serum setting: restore
      $SERUM_PREFS.bak
    (or set "Disable DirectComposition" back to true).

  * Undo the WineASIO re-point: it now points at
      $INSTALL_PREFIX/lib/wine/x86_64-unix/wineasio64.so
    Re-run fl-studio-linux-fix.sh to point it back at the system Wine.

  * Remove everything:  sudo rm -rf "$INSTALL_PREFIX"
    and delete $LAUNCHER, the desktop entry
    ~/.local/share/applications/fl-studio-2026-d2d1.desktop, and the build
    cache $BUILD_ROOT.

  * Rebuild after a fork update:  ./serum2-linux-fix.sh --clean --force-build

  * Build cache:  $BUILD_ROOT
      configure.log / build.log / install.log / wineboot.log

  * If the GUI is still wrong, try the GDI fallback instead: set
    "Disable DirectComposition": true in Serum2Prefs.json. It is supported by
    the same patches and is the more conservative path.
EOF
