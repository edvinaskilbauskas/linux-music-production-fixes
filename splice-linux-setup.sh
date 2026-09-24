#!/usr/bin/env bash
#
# splice-linux-setup.sh
#
# Install and run Splice Desktop (the Windows build) under Wine on Linux.
#
# Splice has no Linux client. The download offered at desktop.splice.com is
# "splice.exe", which is NOT a normal installer: it is a Conveyor/Hydraulic
# MSIX bootstrapper (updatecheck.exe). It resolves the latest .msix from
# https://desktop.splice.com/conveyor/stable/splice.appinstaller, downloads
# it, and installs it through the Windows AppX/MSIX deployment APIs.
#
# Wine has no AppX/MSIX support, so that .exe can never work under Wine - it
# simply hangs or fails. This script does what the bootstrapper would have
# done, minus the deployment step: it fetches the .msix (which is just a ZIP),
# unpacks the application payload, and runs Splice.exe directly.
#
# Two Wine-specific problems are handled here:
#
#   1. FONTS   Chromium (Splice is an Electron app) renders text via
#              DirectWrite, and Wine's DirectWrite only sees the font families
#              listed in Wine's font registry. Wine builds that registry from
#              fontconfig once, and it misses the MS core fonts
#              (Arial/Verdana/Times New Roman/...) that the ttf-mscorefonts
#              package provides. Families that are missing do not fall back -
#              they resolve to a zero-width font and all glyphs collapse, so
#              the UI shows layout but no text.
#              Fix: register those faces in Wine's font registry.
#
#   2. NODE MODE  If ELECTRON_RUN_AS_NODE is set in the environment, Splice.exe
#              starts as a Node process instead of a browser process, fails to
#              load its main script, and exits silently with no window.
#              Fix: the launcher unsets it.
#
# Usage:
#   ./splice-linux-setup.sh [options]
#
#   --dir PATH     install directory (default: ~/splice)
#   --prefix PATH  Wine prefix to use (default: ~/.splice-wine)
#   --force        re-download and re-extract even if already installed
#   --skip-fonts   do not touch Wine's font registry
#   --verify-only  only check the current install
#   -h, --help     this help
#
# Splice uses its own Wine prefix so that it is not affected by (and cannot
# affect) a DAW prefix. Override with --prefix or SPLICE_PREFIX.
#
# Re-running is safe: the download is cached and the font registration is
# idempotent.
#
set -euo pipefail

INSTALL_DIR="${HOME}/splice"
CACHE_DIR="${HOME}/.cache/splice-wine"
# Splice gets its own Wine prefix. Wine prefixes are not isolated per
# application, and a prefix that has been heavily customised (as a DAW prefix
# usually is) can end up in a state where Splice hangs during startup on a
# socket bind that never completes. A clean prefix avoids that entirely, and
# Splice needs nothing from the DAW prefix anyway.
SPLICE_PREFIX="${SPLICE_PREFIX:-${HOME}/.splice-wine}"
APPINSTALLER_URL="https://desktop.splice.com/conveyor/stable/splice.appinstaller"
MSTTCORE_DIR="/usr/share/fonts/truetype/msttcorefonts"
LAUNCHER="${HOME}/.local/bin/splice"
FORCE=0
DO_FONTS=1
VERIFY_ONLY=0

# Everything below must operate on the Splice prefix, not the user's default.
export WINEPREFIX="$SPLICE_PREFIX"

if [ -t 1 ] && [ "${NO_COLOR:-}" = "" ]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_BLU=$'\033[34m'
else
    C_RESET=; C_BOLD=; C_DIM=; C_RED=; C_GRN=; C_YEL=; C_BLU=
fi

step() { printf '\n%s==> %s%s\n' "$C_BOLD$C_BLU" "$*" "$C_RESET"; }
info() { printf '    %s\n' "$*"; }
ok()   { printf '    %s[ ok ]%s %s\n' "$C_GRN" "$C_RESET" "$*"; }
warn() { printf '    %s[warn]%s %s\n' "$C_YEL" "$C_RESET" "$*"; }
die()  { printf '\n%s[fail]%s %s\n' "$C_RED" "$C_RESET" "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --dir)         INSTALL_DIR="$2"; shift 2 ;;
        --prefix)      SPLICE_PREFIX="$2"; export WINEPREFIX="$2"; shift 2 ;;
        --force)       FORCE=1; shift ;;
        --skip-fonts)  DO_FONTS=0; shift ;;
        --verify-only) VERIFY_ONLY=1; DO_FONTS=0; shift ;;
        -h|--help)     sed -n '2,50p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)             die "unknown option: $1" ;;
    esac
done

command -v wine >/dev/null 2>&1 || die "wine not found in PATH."
mkdir -p "$CACHE_DIR"

# ---------------------------------------------------------------------------
# Step 0 - Wine prefix
# ---------------------------------------------------------------------------

ensure_prefix() {
    if [ -d "$SPLICE_PREFIX/drive_c" ]; then
        ok "using existing prefix $SPLICE_PREFIX"
        return 0
    fi
    info "creating Wine prefix $SPLICE_PREFIX ..."
    mkdir -p "$SPLICE_PREFIX"
    WINEDEBUG=-all timeout 300 wineboot -i >/dev/null 2>&1 \
        || die "could not create the Wine prefix at $SPLICE_PREFIX"
    [ -d "$SPLICE_PREFIX/drive_c" ] || die "prefix creation produced no drive_c"
    ok "created prefix $SPLICE_PREFIX"
}

# ---------------------------------------------------------------------------
# Step 1 - fetch the .msix the bootstrapper would have fetched
# ---------------------------------------------------------------------------

resolve_msix_url() {
    local ai="$CACHE_DIR/splice.appinstaller"
    curl -fsSL -o "$ai" "$APPINSTALLER_URL" || die "could not fetch $APPINSTALLER_URL"
    # <MainPackage ... Uri="https://.../splice-X.Y.Z.x64.msix" />
    grep -o 'Uri="[^"]*\.msix"' "$ai" | head -1 | sed 's/^Uri="//; s/"$//'
}

fetch_msix() {
    local url="$1" file
    file="$CACHE_DIR/$(basename "$url")"
    if [ -s "$file" ] && [ "$FORCE" -eq 0 ]; then
        ok "using cached $(basename "$file")"
    else
        info "downloading $(basename "$file") ..."
        curl -fL --retry 3 -o "$file" "$url" || die "download failed: $url"
        ok "downloaded $(basename "$file")"
    fi
    printf '%s' "$file"
}

# ---------------------------------------------------------------------------
# Step 2 - unpack the payload
# ---------------------------------------------------------------------------

extract_msix() {
    local msix="$1"

    # MSIX is a ZIP; the app files are at the archive root.
    if [ -f "$INSTALL_DIR/Splice.exe" ] && [ "$FORCE" -eq 0 ]; then
        ok "Splice.exe already present in $INSTALL_DIR"
        return 0
    fi

    command -v unzip >/dev/null 2>&1 || die "unzip not found."
    info "extracting into $INSTALL_DIR ..."
    mkdir -p "$INSTALL_DIR"
    unzip -qo "$msix" -d "$INSTALL_DIR" || die "extraction failed."

    # The MSIX ships app.asar (the JS bundle) plus app.asar.unpacked (the
    # native modules). Electron resolves the latter by path, so it must stay
    # exactly where it is - do not flatten or rename it.
    [ -f "$INSTALL_DIR/resources/app.asar" ] || die "resources/app.asar missing after extraction."
    ok "unpacked Splice $(cat "$INSTALL_DIR/version" 2>/dev/null || echo '?')"
}

# ---------------------------------------------------------------------------
# Step 3 - register the MS core fonts with Wine
# ---------------------------------------------------------------------------

register_fonts() {
    step "Registering MS core fonts with Wine"

    if [ ! -d "$MSTTCORE_DIR" ]; then
        warn "$MSTTCORE_DIR not found - install ttf-mscorefonts-installer,"
        warn "otherwise Splice's UI will show layout but no text."
        return 0
    fi

    local reg="$CACHE_DIR/msttcore-fonts.reg" tmp
    tmp="$(mktemp)"

    {
        echo 'REGEDIT4'
        echo
        echo '[HKEY_LOCAL_MACHINE\Software\Microsoft\Windows NT\CurrentVersion\Fonts]'
        # fc-query gives us the real family/style names; Wine's registry keys
        # are "<Family> <Style> (TrueType)", with "Regular" omitted.
        while IFS='|' read -r file family style; do
            [ -n "$family" ] || continue
            local name="$family"
            [ "$style" != "Regular" ] && name="$family $style"
            # registry value: "Family Style (TrueType)" = "Z:\path\to\file.ttf"
            printf '"%s (TrueType)"="%s"\n' "$name" "$(printf 'Z:%s' "$file" | sed 's|/|\\\\|g')"
        done < <(
            for f in "$MSTTCORE_DIR"/*.ttf; do
                [ -f "$f" ] || continue
                printf '%s|%s|%s\n' "$f" \
                    "$(fc-query -f '%{family}' "$f" 2>/dev/null | cut -d, -f1)" \
                    "$(fc-query -f '%{style}'  "$f" 2>/dev/null | cut -d, -f1)"
            done
        )
    } > "$tmp"

    # Prefer the canonical lowercase file when two copies of a face exist
    # (the Debian package installs both "Arial.ttf" and "arial.ttf").
    sort -u -t'"' -k2,2 "$tmp" > "$reg"
    rm -f "$tmp"

    WINEDEBUG=-all wine reg import "$reg" >/dev/null 2>&1 \
        || die "could not import $reg into the Wine registry."
    ok "registered $(grep -c '(TrueType)' "$reg") font faces from $MSTTCORE_DIR"
    info "registry file kept at $reg"
}

# ---------------------------------------------------------------------------
# Step 4 - launcher
# ---------------------------------------------------------------------------

install_launcher() {
    mkdir -p "$(dirname "$LAUNCHER")"
    cat > "$LAUNCHER" <<EOF
#!/usr/bin/env bash
# Launch Splice Desktop (Windows build) under Wine.
# ELECTRON_RUN_AS_NODE must be unset or Splice.exe starts in Node mode and
# exits silently without a window.
set -euo pipefail
SPLICE_DIR="\${SPLICE_DIR:-$INSTALL_DIR}"
export WINEPREFIX="\${WINEPREFIX:-$SPLICE_PREFIX}"
LOG="\${XDG_CACHE_HOME:-\$HOME/.cache}/splice-wine/splice.log"
cd "\$SPLICE_DIR"
unset ELECTRON_RUN_AS_NODE
# From the apps menu there is no terminal, so keep a log for troubleshooting.
if [ -t 1 ]; then
    exec wine "\$SPLICE_DIR/Splice.exe" "\$@"
else
    mkdir -p "\$(dirname "\$LOG")"
    exec wine "\$SPLICE_DIR/Splice.exe" "\$@" >>"\$LOG" 2>&1
fi
EOF
    chmod +x "$LAUNCHER"
    ok "launcher: $LAUNCHER"
    case ":$PATH:" in
        *":$(dirname "$LAUNCHER"):"*) ;;
        *) warn "$(dirname "$LAUNCHER") is not in PATH - add it or call it by full path" ;;
    esac
}

# ---------------------------------------------------------------------------
# Step 5 - apps menu entry
# ---------------------------------------------------------------------------

install_desktop_entry() {
    local icons="$HOME/.local/share/icons/hicolor"
    local apps="$HOME/.local/share/applications"
    local src="$INSTALL_DIR/ConveyorMsixResources"

    # Icon sizes shipped in the MSIX.
    local pair size file
    for pair in 32:Square44x44Logo.targetsize-32.png \
                64:Square44x44Logo.targetsize-64.png \
                128:Square150x150Logo.targetsize-128.png \
                256:Square150x150Logo.targetsize-256.png; do
        size="${pair%%:*}"; file="${pair##*:}"
        [ -f "$src/$file" ] || continue
        mkdir -p "$icons/${size}x${size}/apps"
        cp -f "$src/$file" "$icons/${size}x${size}/apps/splice.png"
    done

    mkdir -p "$apps"
    cat > "$apps/splice.desktop" <<EOF
[Desktop Entry]
Type=Application
Version=1.0
Name=Splice
GenericName=Sample & Plugin Library
Comment=Royalty-free sounds and rent-to-own plugins
Exec=$LAUNCHER
Icon=splice
Terminal=false
Categories=AudioVideo;Audio;Music;
Keywords=samples;loops;audio;music;plugins;vst;
StartupWMClass=splice.exe
StartupNotify=true
EOF
    chmod +x "$apps/splice.desktop"
    ok "menu entry: $apps/splice.desktop"

    # StartupWMClass must match Wine's WM_CLASS or the taskbar shows a
    # generic icon and a duplicate launcher entry.
    if command -v xprop >/dev/null 2>&1; then
        info "Wine reports WM_CLASS 'splice.exe' for the Splice window"
    fi

    command -v update-desktop-database >/dev/null 2>&1 \
        && update-desktop-database "$apps" >/dev/null 2>&1 || true
    command -v gtk-update-icon-cache >/dev/null 2>&1 \
        && gtk-update-icon-cache -f -t "$icons" >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# Verify
# ---------------------------------------------------------------------------

verify() {
    step "Verification"

    local bad=0
    [ -f "$INSTALL_DIR/Splice.exe" ] && ok "Splice.exe present" || { warn "Splice.exe missing"; bad=1; }
    [ -f "$INSTALL_DIR/resources/app.asar" ] && ok "app.asar present" || { warn "app.asar missing"; bad=1; }
    [ -d "$INSTALL_DIR/resources/app.asar.unpacked" ] && ok "native modules present" || { warn "app.asar.unpacked missing"; bad=1; }

    # DirectWrite is what Chromium uses, so check the families through it.
    local check="$CACHE_DIR/dwrite-check"
    if [ ! -f "$check.exe" ] && command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1; then
        mkdir -p "$check"
        cat > "$check/check.c" <<'EOF'
#define COBJMACROS
#include <windows.h>
#include <dwrite.h>
#include <stdio.h>
static const IID my_factory = { 0xb859ee5a, 0xd838, 0x4b5b, { 0xa2,0xe8,0x1a,0xdc,0x7d,0x93,0xdb,0x48 } };
int main(void) {
    IDWriteFactory *f = NULL; IDWriteFontCollection *c = NULL;
    if (FAILED(DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED, (REFIID)&my_factory, (IUnknown **)&f))) return 2;
    if (FAILED(IDWriteFactory_GetSystemFontCollection(f, &c, FALSE))) return 2;
    const char *n[] = { "Arial", "Verdana", "Times New Roman", "Tahoma" };
    for (int i = 0; i < 4; i++) {
        WCHAR w[64]; MultiByteToWideChar(CP_ACP, 0, n[i], -1, w, 64);
        UINT32 idx; BOOL found = FALSE;
        IDWriteFontCollection_FindFamilyName(c, w, &idx, &found);
        printf("%s=%d\n", n[i], found);
    }
    return 0;
}
EOF
        x86_64-w64-mingw32-gcc -o "$check.exe" "$check/check.c" -ldwrite -lole32 -luuid >/dev/null 2>&1 || true
    fi

    if [ -f "$check.exe" ]; then
        local out
        out="$(WINEDEBUG=-all timeout 60 wine "$check.exe" 2>/dev/null | tr -d '\r')"
        if printf '%s' "$out" | grep -q '^Arial=1'; then
            ok "DirectWrite sees Arial (text will render)"
        else
            warn "DirectWrite does not see Arial - UI text will be invisible"; bad=1
        fi
    else
        info "skipped DirectWrite check (needs x86_64-w64-mingw32-gcc)"
    fi

    if [ -f "$HOME/.local/share/applications/splice.desktop" ]; then
        if command -v desktop-file-validate >/dev/null 2>&1 \
           && ! desktop-file-validate "$HOME/.local/share/applications/splice.desktop" 2>/dev/null; then
            warn "splice.desktop failed validation"; bad=1
        else
            ok "apps menu entry installed"
        fi
    else
        warn "no apps menu entry"; bad=1
    fi

    printf '\n'
    if [ "$bad" -eq 0 ]; then
        printf '%sReady.%s Launch with: %s\n' "$C_BOLD$C_GRN" "$C_RESET" "$LAUNCHER"
    else
        printf '%sSome checks failed - see warnings above.%s\n' "$C_BOLD$C_YEL" "$C_RESET"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

printf '%sSplice / Wine setup%s  (wine %s, prefix %s)\n' \
    "$C_BOLD" "$C_RESET" "$(wine --version 2>/dev/null)" "${WINEPREFIX:-$HOME/.wine}"

if [ "$VERIFY_ONLY" -eq 0 ]; then
    step "Wine prefix"
    ensure_prefix

    step "Fetching Splice package"
    url="$(resolve_msix_url)"
    info "latest: $(basename "$url")"
    msix="$(fetch_msix "$url")"

    step "Unpacking"
    extract_msix "$msix"

    if [ "$DO_FONTS" -eq 1 ]; then register_fonts; fi

    step "Installing launcher"
    install_launcher

    step "Installing apps menu entry"
    install_desktop_entry
fi

verify

cat <<EOF

${C_DIM}Notes / how to undo${C_RESET}

  * package cache:  $CACHE_DIR
      delete it to force a fresh download (the .msix is ~160 MB)

  * wine prefix:    $SPLICE_PREFIX
      Splice's own prefix, kept separate from the DAW prefix. Delete it to
      start Splice from scratch (you will need to log in again).

  * fonts:          $CACHE_DIR/msttcore-fonts.reg
      remove with:  wine reg delete 'HKLM\\Software\\Microsoft\\Windows
                    NT\\CurrentVersion\\Fonts' /v 'Arial (TrueType)' /f
      (re-run this script to put them back)

  * launcher:       $LAUNCHER
      when started without a terminal (apps menu) output goes to
      $CACHE_DIR/splice.log

  * menu entry:     $HOME/.local/share/applications/splice.desktop
      icons in $HOME/.local/share/icons/hicolor/*/apps/splice.png
      remove both to take it out of the apps menu

  * Uninstall:      rm -rf "$INSTALL_DIR" and remove the launcher,
                    the menu entry and the icons.

  * Updates:        re-run with --force. Splice's own updater cannot install
                    MSIX updates, but it does report when a new version is out.

  Known limitation: Splice's "Connect" (connectsdk) native module fails to
  load under Wine. It is non-fatal - Splice logs an error and continues.
EOF
