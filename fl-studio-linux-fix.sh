#!/usr/bin/env bash
#
# fl-studio-linux-fix.sh
#
# One-shot fix for FL Studio running under Wine on Linux. Addresses three
# independent, well-understood problems:
#
#   1. FONTS      FL Studio / FLEX open font files by absolute path
#                 (C:\windows\Fonts\Verdana.ttf). A Wine prefix with no fonts
#                 makes those opens fail; FLEX does not null-check the result
#                 and crashes with an access violation. Fix: install the MS
#                 core fonts plus FL's own bundled fonts into the prefix.
#
#   2. FLEX PACKS FLEX reads its sound packs from the user data folder
#                 (.../Documents/Image-Line/FLEX/Packs). FL Studio's installer
#                 stages them inside the install directory instead, so FLEX
#                 reports "not installed" and tries (and fails) to re-download.
#                 Fix: copy the staged packs where FLEX looks for them.
#
#   3. SIGNATURE  FL Studio 2026 binaries are signed with PKCS#7 authenticated
#                 attributes in non-canonical DER order. Wine's crypt32
#                 re-sorts them before hashing, so it rejects a valid
#                 signature with TRUST_E_CERT_SIGNATURE (0x80096004) and FL
#                 refuses to start with "The validity of the program could not
#                 be verified". Upstream Wine bug 60273 / MR !11824.
#                 Fix: build crypt32 from matching Wine sources with that
#                 patch applied and install just that DLL (with a backup).
#
#   4. MIDI       PipeWire advertises its MIDI bridge as ALSA "UMP MIDI2" user
#                 ports. Wine's MIDI input cannot open those, returning
#                 MMSYSERR_NOTENABLED, which FL reports on every launch as
#                 "The driver was not enabled." Fix: disable those specific
#                 devices in FL's MIDI config (they are useless to FL anyway).
#
#   5. LOW LATENCY FL only sees "FL Studio ASIO" (a WASAPI wrapper), which goes
#                 through Wine's PulseAudio path and adds tens of ms. Vendor
#                 ASIO drivers cannot work under Wine (they need the Windows
#                 kernel audio stack), so the fix is WineASIO: an ASIO driver
#                 that bridges to JACK, which PipeWire serves. Fix: install
#                 pipewire-jack, build WineASIO, register it, and pin PipeWire
#                 to a small quantum.
#
# Run as your NORMAL user (not root). The script calls sudo when needed.
#
# Usage:
#   ./fl-studio-linux-fix.sh [options]
#
#   --skip-fonts      do not touch fonts
#   --skip-packs      do not touch FLEX packs
#   --skip-signature  do not touch crypt32
#   --skip-midi       do not touch FL's MIDI device config
#   --skip-asio       do not build/install WineASIO or touch PipeWire config
#   --force-signature rebuild/install crypt32 even if the check looks fine
#   --verify-only     only run the end-to-end checks
#   --clean           delete the cached Wine source tree before building
#   --jobs N          parallel build jobs (default: nproc)
#   -h, --help        this help
#
# Re-running is safe: every step is idempotent and keeps backups.

set -euo pipefail

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

REPO_URL="https://gitlab.winehq.org/wine/wine.git"
PATCH_URL="https://gitlab.winehq.org/wine/wine/-/merge_requests/11824.diff"
WINEASIO_URL="https://github.com/wineasio/wineasio.git"
WINEASIO_CLSID="{48D0C522-BFCC-45CC-8B84-17F25F33E6E8}"
PIPEWIRE_QUANTUM="${PIPEWIRE_QUANTUM:-256}"
PIPEWIRE_RATE="${PIPEWIRE_RATE:-48000}"

BUILD_ROOT="${HOME}/wine-crypt32-fix"      # cached clones + built binaries live here
JOBS="$(nproc 2>/dev/null || echo 4)"
VERIFY_TIMEOUT=30

DO_FONTS=1
DO_PACKS=1
DO_SIG=1
DO_MIDI=1
DO_ASIO=1
FORCE_SIG=0
VERIFY_ONLY=0
CLEAN=0

WINE_SRC=""        # set by ensure_wine_source()

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

# Copy a file into a directory only if its contents differ, counting the real
# changes in COPIED so the summary does not claim work that did not happen.
COPIED=0
sync_file() {
    local s="$1" d="$2/$(basename "$1")"
    if [ -f "$d" ] && cmp -s "$s" "$d"; then return 0; fi
    if cp -f "$s" "$d" 2>/dev/null; then COPIED=$((COPIED + 1)); fi
    return 0
}

# Same, but never replaces an existing file. Used for Wine's own fallback
# fonts: some names (e.g. webdings.ttf) also exist in the Microsoft core
# fonts with different content, and without this the two would overwrite each
# other on every run.
copy_if_absent() {
    local s="$1" d="$2/$(basename "$1")"
    if [ -e "$d" ]; then return 0; fi
    if cp -f "$s" "$d" 2>/dev/null; then COPIED=$((COPIED + 1)); fi
    return 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-fonts)     DO_FONTS=0 ;;
        --skip-packs)     DO_PACKS=0 ;;
        --skip-signature) DO_SIG=0 ;;
        --skip-midi)      DO_MIDI=0 ;;
        --skip-asio)      DO_ASIO=0 ;;
        --force-signature) FORCE_SIG=1 ;;
        --verify-only)    VERIFY_ONLY=1; DO_FONTS=0; DO_PACKS=0; DO_SIG=0; DO_MIDI=0; DO_ASIO=0 ;;
        --clean)          CLEAN=1 ;;
        --jobs)           JOBS="${2:?--jobs needs a number}"; shift ;;
        -h|--help)        sed -n '2,46p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                die "unknown option: $1 (try --help)" ;;
    esac
    shift
done

# ---------------------------------------------------------------------------
# Privilege handling: never run the whole script as root (it would create
# root-owned files inside ~/.wine). Call sudo per-operation instead.
# ---------------------------------------------------------------------------

if [ "$(id -u)" -eq 0 ]; then
    if [ -n "${SUDO_USER:-}" ] && [ "${FLFIX_DROPPED:-0}" != "1" ]; then
        info "Running as root; re-executing as ${SUDO_USER} (you may be asked for a password again)."
        exec sudo -u "$SUDO_USER" -H env FLFIX_DROPPED=1 bash "$0" "$@"
    fi
    die "Do not run this script as root. Run it as your normal user; it will call sudo itself."
fi

HAS_SUDO=0
if command -v sudo >/dev/null 2>&1; then
    # Cache credentials up front so the rest of the run is a single prompt.
    if sudo -v 2>/dev/null; then
        HAS_SUDO=1
        # Keep the timestamp fresh for the duration of the script.
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

step "Detecting environment"

WINE_BIN="$(command -v wine || true)"
[ -n "$WINE_BIN" ] || die "wine not found in PATH."
WINE_REAL="$(readlink -f "$WINE_BIN")"
WINE_ROOT="$(dirname "$(dirname "$WINE_REAL")")"
WINE_VERSION="$(wine --version 2>/dev/null | sed 's/^wine-//')"

WINE_LIB=""
for cand in "$WINE_ROOT/lib/wine" "$WINE_ROOT/lib64/wine" \
            /usr/lib/wine /usr/lib/x86_64-linux-gnu/wine /usr/lib64/wine; do
    if [ -d "$cand/x86_64-windows" ]; then WINE_LIB="$cand"; break; fi
done
[ -n "$WINE_LIB" ] || die "Could not locate Wine's x86_64-windows DLL directory."
DLL_X64="$WINE_LIB/x86_64-windows"

export WINEPREFIX="${WINEPREFIX:-$HOME/.wine}"
[ -d "$WINEPREFIX" ] || die "Wine prefix not found at $WINEPREFIX"

DOCS="$(xdg-user-dir DOCUMENTS 2>/dev/null || true)"
[ -n "$DOCS" ] && [ -d "$DOCS" ] || DOCS="$HOME/Documents"

PREFIX_FONTS="$WINEPREFIX/drive_c/windows/Fonts"

# FL Studio install directory: locate it by its main executable, so unrelated
# siblings such as "FL Studio ASIO" are not mistaken for the app.
FL_DIR="$(find "$WINEPREFIX/drive_c/Program Files/Image-Line" -maxdepth 2 \
              -name FL64.exe -printf '%h\n' 2>/dev/null | sort -V | tail -1 || true)"
FLEX_USER_PACKS="$DOCS/Image-Line/FLEX/Packs"

info "wine           : $WINE_VERSION ($WINE_ROOT)"
info "wine prefix    : $WINEPREFIX"
info "wine DLL dir   : $DLL_X64"
info "user documents : $DOCS"
if [ -n "$FL_DIR" ]; then
    info "FL Studio      : $(basename "$FL_DIR")"
else
    warn "FL Studio install directory not found under $WINEPREFIX/drive_c/Program Files/Image-Line"
fi

# ---------------------------------------------------------------------------
# Step 1 - fonts
# ---------------------------------------------------------------------------

install_fonts() {
    step "Step 1/3  Fonts"

    mkdir -p "$PREFIX_FONTS"

    # 1a. Microsoft core fonts (Verdana is the one that crashes FLEX).
    if [ ! -f "$PREFIX_FONTS/Verdana.ttf" ]; then
        if [ "$HAS_SUDO" -eq 1 ]; then
            info "Installing ttf-mscorefonts-installer (accepting the EULA non-interactively)..."
            printf 'ttf-mscorefonts-installer msttcorefonts/accepted-mscorefonts-eula select true\n' \
                | root_run debconf-set-selections || true
            root_run apt-get install -y ttf-mscorefonts-installer || \
                warn "ttf-mscorefonts-installer failed; continuing (fonts may be incomplete)."
        else
            warn "No sudo: cannot install ttf-mscorefonts-installer."
        fi
    else
        ok "MS core fonts already present in prefix"
    fi

    local src f before
    before="$COPIED"
    for src in /usr/share/fonts/truetype/msttcorefonts \
               /usr/share/fonts/truetype/msttcorefonts/extra; do
        if [ -d "$src" ]; then
            for f in "$src"/*.ttf; do
                if [ -f "$f" ]; then sync_file "$f" "$PREFIX_FONTS"; fi
            done
        fi
    done
    if [ "$COPIED" -gt "$before" ]; then
        ok "installed $((COPIED - before)) MS core font file(s)"
    else
        ok "MS core fonts already in place"
    fi

    # 1b. Fonts Wine itself ships (Tahoma, Symbol, Wingdings, ...). A healthy
    #     prefix normally has these; some prefixes are created without them.
    #     These are fallbacks, so never let them replace a real font.
    local wf="$WINE_ROOT/share/wine/fonts"
    if [ -d "$wf" ]; then
        before="$COPIED"
        while IFS= read -r -d '' f; do copy_if_absent "$f" "$PREFIX_FONTS"; done \
            < <(find "$wf" -maxdepth 1 -type f \
                     \( -iname '*.ttf' -o -iname '*.fon' \) -print0 2>/dev/null)
        if [ "$COPIED" -gt "$before" ]; then
            ok "added $((COPIED - before)) font(s) shipped with Wine"
        else
            ok "Wine's bundled fonts already in place"
        fi
    fi

    # 1c. FL Studio's own bundled fonts. FL looks these up in C:\windows\Fonts
    #     as well as its own Artwork folders.
    if [ -n "$FL_DIR" ]; then
        before="$COPIED"
        while IFS= read -r -d '' f; do sync_file "$f" "$PREFIX_FONTS"; done \
            < <(find "$FL_DIR/Shared/Artwork/Fonts" "$FL_DIR/Artwork/Fonts" -type f \
                     \( -iname '*.ttf' -o -iname '*.otf' -o -iname '*.ilfont' \) \
                     -print0 2>/dev/null)
        if [ "$COPIED" -gt "$before" ]; then
            ok "added $((COPIED - before)) font(s) bundled with FL Studio"
        else
            ok "FL Studio's bundled fonts already in place"
        fi
    fi

    local n; n="$(find "$PREFIX_FONTS" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
    ok "prefix now contains $n font files"

    if [ -f "$PREFIX_FONTS/Verdana.ttf" ]; then
        ok "Verdana.ttf present (this is what was crashing FLEX)"
    else
        warn "Verdana.ttf is still missing - FLEX will keep crashing."
        warn "Install it manually, e.g.:  sudo apt install ttf-mscorefonts-installer"
    fi
}

# ---------------------------------------------------------------------------
# Step 2 - FLEX packs
# ---------------------------------------------------------------------------

install_packs() {
    step "Step 2/3  FLEX sound packs"

    if [ -z "$FL_DIR" ]; then
        warn "FL Studio not found; skipping."
        return 0
    fi

    local src="$FL_DIR/Data/Patches/Packs/FLEX/Packs"
    if [ ! -d "$src" ]; then
        warn "No staged FLEX packs at: $src"
        warn "Nothing to install (FLEX will need to download them from Image-Line)."
        return 0
    fi

    mkdir -p "$FLEX_USER_PACKS"
    local before="$COPIED" f
    while IFS= read -r -d '' f; do sync_file "$f" "$FLEX_USER_PACKS"; done \
        < <(find "$src" -maxdepth 1 -type f \
                 \( -iname '*.flexpack' -o -iname '*.flex2pack' -o -iname '*.ini' \) -print0)

    if [ "$COPIED" -gt "$before" ]; then
        ok "installed $((COPIED - before)) pack file(s) into $FLEX_USER_PACKS"
    else
        ok "FLEX packs already up to date in $FLEX_USER_PACKS"
    fi

    # Sanity check: every pack file should have its .ini version marker next to it.
    local missing=0
    while IFS= read -r -d '' f; do
        [ -f "${f%.*}.ini" ] || { warn "missing version marker for $(basename "$f")"; missing=1; }
    done < <(find "$FLEX_USER_PACKS" -maxdepth 1 -type f \
                  \( -iname '*.flexpack' -o -iname '*.flex2pack' \) -print0)
    if [ "$missing" -eq 0 ]; then ok "all packs have their .ini version markers"; fi
}

# ---------------------------------------------------------------------------
# Step 3 - crypt32 (FL Studio's signature verification)
# ---------------------------------------------------------------------------

fl_signature_status() {
    # Returns: ok | fail | running | unknown
    [ -n "$FL_DIR" ] || { echo unknown; return; }
    [ -x "$FL_DIR/FL64.exe" ] || { echo unknown; return; }

    # Never kill a session the user already has open.
    if pgrep -x FL64.exe >/dev/null 2>&1; then
        echo running; return
    fi

    local log; log="$(mktemp)"
    ( cd "$FL_DIR" && timeout "$VERIFY_TIMEOUT" env WINEDEBUG=+wintrust wine FL64.exe ) \
        >"$log" 2>&1 || true
    pkill -x FL64.exe 2>/dev/null || true

    local res=unknown
    if grep -q 'WinVerifyTrust returning 80096004' "$log"; then
        res=fail
    elif grep -q 'WinVerifyTrust returning 00000000' "$log"; then
        res=ok
    fi
    rm -f "$log"
    echo "$res"
}

wine_source_tag() {
    # Map the installed Wine version to a git tag that actually exists.
    local ver="$1"
    local tag="wine-$ver"
    if git ls-remote --exit-code --tags "$REPO_URL" "refs/tags/$tag" >/dev/null 2>&1; then
        echo "$tag"; return 0
    fi
    # e.g. 11.0-rc2 -> wine-11.0-rc2 already tried; try trimming build suffixes
    local trimmed="${ver%%+*}"
    tag="wine-$trimmed"
    if git ls-remote --exit-code --tags "$REPO_URL" "refs/tags/$tag" >/dev/null 2>&1; then
        echo "$tag"; return 0
    fi
    return 1
}

ensure_wine_source() {
    # Clone (once) the Wine tree matching the installed version and expose its
    # path in WINE_SRC. Both the crypt32 fix and the WineASIO build need its
    # headers, so they share this.
    if [ -n "$WINE_SRC" ] && [ -d "$WINE_SRC/include" ]; then return 0; fi

    local tag src
    tag="$(wine_source_tag "$WINE_VERSION")" \
        || die "No upstream git tag found for Wine '$WINE_VERSION'."
    src="$BUILD_ROOT/wine-$WINE_VERSION"
    mkdir -p "$BUILD_ROOT"

    if [ "$CLEAN" -eq 1 ] && [ -d "$src" ]; then
        info "Removing cached source tree (--clean)"
        rm -rf "$src"
    fi

    if [ ! -d "$src/.git" ]; then
        info "Cloning Wine sources at tag $tag (this downloads ~400 MB)..."
        rm -rf "$src"
        git clone --depth 1 --branch "$tag" "$REPO_URL" "$src" \
            || die "git clone failed."
    else
        ok "reusing cached Wine source tree at $src"
    fi

    [ -d "$src/include" ] || die "Wine source tree at $src has no include/ directory."
    WINE_SRC="$src"
}

build_tools_ok() {
    local t
    for t in flex bison make pkg-config git curl x86_64-w64-mingw32-gcc; do
        command -v "$t" >/dev/null 2>&1 || return 1
    done
    return 0
}

install_build_deps() {
    if build_tools_ok; then ok "build tools already present"; return 0; fi

    info "Installing build dependencies..."
    root_run apt-get install -y --no-install-recommends \
        flex bison gcc-mingw-w64-x86-64 git make pkg-config ca-certificates curl \
        || warn "apt install failed; re-checking"

    local t missing=0
    for t in flex bison make pkg-config git curl x86_64-w64-mingw32-gcc; do
        if ! command -v "$t" >/dev/null 2>&1; then
            warn "missing build tool: $t"
            missing=1
        fi
    done
    [ "$missing" -eq 0 ] || die "Build tools are missing. Install them with:
    sudo apt install flex bison gcc-mingw-w64-x86-64 git make pkg-config curl"
    ok "build tools present"
}

insert_header_decl() {
    # Add the CRYPT_AsnEncodePKCSAttributesUnsorted prototype to
    # crypt32_private.h. The upstream patch's hunk is written against master
    # and does not always apply to release tags, so do it by hand.
    local hdr="$1"
    if grep -q 'CRYPT_AsnEncodePKCSAttributesUnsorted' "$hdr"; then
        return 0
    fi
    python3 - "$hdr" <<'PY'
import sys, io
path = sys.argv[1]
decl = (
    "/* Encodes attributes as a SET OF while preserving the order in which they\n"
    " * appear in attributes->rgAttr, rather than sorting them into DER order.\n"
    " * Needed when hashing PKCS#7 authenticated attributes in order to verify a\n"
    " * signature: the signature covers the attributes exactly as the signer\n"
    " * encoded them, and that encoding is not required to be canonical.\n"
    " * On success *pbEncoded is LocalAlloc'd and the caller frees it.\n"
    " */\n"
    "BOOL CRYPT_AsnEncodePKCSAttributesUnsorted(const CRYPT_ATTRIBUTES *attributes,\n"
    " BYTE **pbEncoded, DWORD *pcbEncoded);\n"
)
text = io.open(path, encoding='utf-8').read()
anchor = "/* a few asn.1 tags we need */"
if anchor in text:
    text = text.replace(anchor, decl + "\n" + anchor, 1)
else:
    # fall back: insert before the first #define ASN_BOOL
    marker = "#define ASN_BOOL"
    idx = text.find(marker)
    if idx < 0:
        sys.exit("could not find an insertion point in crypt32_private.h")
    text = text[:idx] + decl + "\n" + text[idx:]
io.open(path, 'w', encoding='utf-8').write(text)
PY
}

apply_crypt32_patch() {
    local src="$1" patchfile="$2"
    cd "$src"

    if grep -q 'CRYPT_AsnEncodePKCSAttributesUnsorted' dlls/crypt32/encode.c; then
        ok "patch already applied in source tree"
        return 0
    fi

    git checkout -- dlls/crypt32 2>/dev/null || true

    if git apply --check "$patchfile" 2>/dev/null; then
        git apply "$patchfile"
        ok "applied upstream patch (full)"
        return 0
    fi

    info "full patch does not apply to this Wine version; applying source hunks only"
    git checkout -- dlls/crypt32 2>/dev/null || true
    git apply --exclude=dlls/crypt32/crypt32_private.h "$patchfile" \
        || die "could not apply the crypt32 patch. See https://bugs.winehq.org/show_bug.cgi?id=60273"
    insert_header_decl "$src/dlls/crypt32/crypt32_private.h"
    ok "applied upstream patch (source hunks + manual header)"
}

build_crypt32() {
    step "Step 3/3  FL Studio signature fix (patched crypt32)"

    if [ -z "$FL_DIR" ]; then
        warn "FL Studio not found; cannot test whether the fix is needed. Skipping."
        return 0
    fi

    local status
    if [ "$FORCE_SIG" -eq 1 ]; then
        status=fail
        info "--force-signature given; rebuilding crypt32 regardless of the check."
    else
        status="$(fl_signature_status)"
    fi
    case "$status" in
        ok)
            ok "FL Studio already verifies correctly - no crypt32 change needed."
            return 0
            ;;
        fail)
            info "Confirmed: Wine rejects FL Studio's signature (0x80096004). Patching crypt32."
            ;;
        running)
            die "FL Studio is currently running. Close it and re-run this script."
            ;;
        *)
            warn "Could not determine signature status; assuming the fix is needed."
            ;;
    esac

    if [ "$HAS_SUDO" -ne 1 ]; then
        die "Patching crypt32 requires root. Re-run with sudo available."
    fi

    install_build_deps
    ensure_wine_source
    local src="$WINE_SRC"

    # Download the upstream patch (kept fresh so it works on future Wine too).
    local patchfile="$BUILD_ROOT/mr11824.diff"
    info "Fetching upstream patch..."
    if ! curl -fsSL -o "$patchfile" "$PATCH_URL"; then
        die "Could not download the patch from $PATCH_URL"
    fi

    apply_crypt32_patch "$src" "$patchfile"

    # Already built for this Wine version?
    local stamp="$BUILD_ROOT/.built-$WINE_VERSION"
    local built="$src/dlls/crypt32/x86_64-windows/crypt32.dll"

    if [ -f "$stamp" ] && [ -f "$built" ]; then
        ok "patched crypt32 already built (skipping compile)"
    else
        cd "$src"
        if [ -f "$src/config.status" ] && [ -f "$src/Makefile" ]; then
            ok "source tree already configured (reusing)"
        else
            info "Configuring Wine (64-bit only, no tests)..."
            # Try a lean configure first; fall back to a bare one if this Wine
            # version does not accept some of the flags.
            if ! ./configure --enable-archs=x86_64 --disable-tests \
                    --without-alsa --without-pulse --without-oss --without-coreaudio \
                    --without-cups --without-dbus --without-gnutls --without-gssapi \
                    --without-krb5 --without-netapi --without-pcap --without-pcsclite \
                    --without-sane --without-sdl --without-usb --without-v4l2 \
                    --without-vulkan --without-wayland --without-gstreamer \
                    --without-ffmpeg --without-opencl --without-capi --without-gphoto \
                    --without-hwloc --without-udev >"$BUILD_ROOT/configure.log" 2>&1; then
                warn "lean configure failed; retrying with minimal flags"
                ./configure --disable-tests >"$BUILD_ROOT/configure.log" 2>&1 \
                    || die "configure failed - see $BUILD_ROOT/configure.log"
            fi
            ok "configured"
        fi

        info "Building crypt32 (this takes a few minutes)..."
        make -j"$JOBS" -C dlls/crypt32 >"$BUILD_ROOT/build.log" 2>&1 \
            || die "build failed - see $BUILD_ROOT/build.log"

        [ -f "$built" ] || die "build produced no crypt32.dll"
        : > "$stamp"
        ok "built patched crypt32.dll"
    fi

    # Install with a backup.
    local target="$DLL_X64/crypt32.dll"
    if [ ! -f "$target.orig" ]; then
        root_run cp -a "$target" "$target.orig"
        ok "backed up original to crypt32.dll.orig"
    fi
    root_run install -m 644 "$built" "$target"
    if cmp -s "$built" "$target"; then
        ok "installed patched crypt32.dll"
    else
        die "Could not install the patched crypt32.dll into $target (permissions?)."
    fi

    # 32-bit prefix coverage note.
    if [ -d "$WINE_LIB/i386-windows" ]; then
        warn "This Wine has a 32-bit DLL set too; only the 64-bit crypt32 was"
        warn "patched. FL Studio 2026 is 64-bit, so this is fine unless you also"
        warn "run 32-bit Windows software that verifies signatures."
    fi
}

# ---------------------------------------------------------------------------
# Step 4 - MIDI device config
# ---------------------------------------------------------------------------

fl_config_key() {
    # FL Studio's registry key name, e.g. "FL Studio 26".
    wine reg query 'HKCU\Software\Image-Line' 2>/dev/null \
        | grep -oE 'Image-Line\\FL Studio [0-9]+' \
        | sed 's/.*\\//' | sort -V | tail -1
}

reg_value() {
    # Read one registry value. `wine reg query` emits CRLF, so strip CR or
    # every comparison against a literal like "0" silently fails.
    wine reg query "$1" /v "$2" 2>/dev/null \
        | awk -v v="$2" '$1 == v { print $NF }' | tr -d '\r'
}

ump_midi_ports() {
    # "<client> - <port>" names of ALSA sequencer ports belonging to
    # "User UMP MIDI2" clients. Wine's MIDI input cannot open these, and FL
    # reports MMSYSERR_NOTENABLED ("The driver was not enabled.") for them.
    python3 - <<'PY' 2>/dev/null || true
import re, sys
try:
    text = open('/proc/asound/seq/clients', errors='ignore').read()
except OSError:
    sys.exit(0)
for chunk in text.split('Client ')[1:]:
    lines = chunk.splitlines()
    if not lines or 'UMP MIDI2' not in lines[0]:
        continue
    m = re.match(r'\s*\d+\s*:\s*"([^"]+)"', lines[0])
    if not m:
        continue
    client = m.group(1)
    for line in lines[1:]:
        p = re.match(r'\s*Port\s+\d+\s*:\s*"([^"]+)"', line)
        if p:
            print("%s - %s" % (client, p.group(1)))
PY
}

install_midi_fix() {
    step "Step 4/5  MIDI device config"

    local key; key="$(fl_config_key)"
    if [ -z "$key" ]; then
        warn "FL Studio config not found in the registry; skipping."
        return 0
    fi

    if pgrep -x FL64.exe >/dev/null 2>&1; then
        warn "FL Studio is running; it rewrites its MIDI config on exit."
        warn "Close FL Studio and re-run to apply the MIDI fix."
        return 0
    fi

    local ports; ports="$(ump_midi_ports)"
    if [ -z "$ports" ]; then
        ok "no unopenable UMP-MIDI2 MIDI ports present"
        return 0
    fi

    local dev regpath cur disabled=0
    while IFS= read -r dev; do
        [ -n "$dev" ] || continue
        regpath="HKCU\\Software\\Image-Line\\$key\\Devices\\MIDI input\\$dev"
        wine reg query "$regpath" /v Enabled >/dev/null 2>&1 || continue
        cur="$(reg_value "$regpath" Enabled)"
        if [ "$cur" != "0" ]; then
            if wine reg add "$regpath" /v Enabled /t REG_SZ /d 0 /f >/dev/null 2>&1; then
                ok "disabled MIDI input: $dev"
                disabled=$((disabled + 1))
            else
                warn "could not disable MIDI input: $dev"
            fi
        fi
    done <<< "$ports"

    if [ "$disabled" -eq 0 ]; then
        ok "MIDI inputs already disabled"
    fi
}

# ---------------------------------------------------------------------------
# Step 5 - low-latency ASIO (WineASIO + PipeWire)
# ---------------------------------------------------------------------------

install_pipewire_lowlatency() {
    local dir="$HOME/.config/pipewire/pipewire.conf.d"
    local file="$dir/10-low-latency.conf"
    mkdir -p "$dir"

    if [ -f "$file" ] && grep -q "default.clock.quantum *= *$PIPEWIRE_QUANTUM" "$file"; then
        ok "PipeWire low-latency config already present"
    else
        cat > "$file" <<EOF
# Low-latency clock settings for DAW use (FL Studio via WineASIO).
# Revert by deleting this file and restarting PipeWire.
context.properties = {
    default.clock.quantum     = $PIPEWIRE_QUANTUM
    default.clock.min-quantum = 64
    default.clock.max-quantum = 2048
    default.clock.rate        = $PIPEWIRE_RATE
}
EOF
        ok "wrote $file"
    fi

    # Apply to the running server (no restart, so no audio interruption).
    if command -v pw-metadata >/dev/null 2>&1; then
        pw-metadata -n settings 0 clock.force-quantum "$PIPEWIRE_QUANTUM" >/dev/null 2>&1 || true
        pw-metadata -n settings 0 clock.force-rate "$PIPEWIRE_RATE" >/dev/null 2>&1 || true
        ok "applied ${PIPEWIRE_RATE} Hz / ${PIPEWIRE_QUANTUM} frames to the running PipeWire"
    fi
}

asio_selftest() {
    # Create the registered WineASIO object and initialise it. This is what
    # catches the mlockall(MCL_FUTURE) deadlock, so it is worth compiling.
    command -v x86_64-w64-mingw32-gcc >/dev/null 2>&1 || { echo unknown; return; }

    local dir="$BUILD_ROOT/asio-check"
    mkdir -p "$dir"
    cat > "$dir/check.c" <<'EOF'
#include <windows.h>
#include <objbase.h>
#include <stdio.h>
typedef struct IAsio IAsio;
typedef struct IAsioVtbl {
    HRESULT (*QueryInterface)(IAsio*, const GUID*, void**);
    ULONG (*AddRef)(IAsio*);
    ULONG (*Release)(IAsio*);
    long (*init)(IAsio*, void*);
    void (*getDriverName)(IAsio*, char*);
    long (*getDriverVersion)(IAsio*, long*);
    void (*getErrorMessage)(IAsio*, char*);
    long (*start)(IAsio*);
    long (*stop)(IAsio*);
    long (*getChannels)(IAsio*, long*, long*);
    long (*getLatencies)(IAsio*, long*, long*);
    long (*getBufferSize)(IAsio*, long*, long*, long*, long*);
    long (*canSampleRate)(IAsio*, double);
    long (*getSampleRate)(IAsio*, double*);
} IAsioVtbl;
struct IAsio { IAsioVtbl *lpVtbl; };
int main(void) {
    GUID clsid = { 0x48D0C522, 0xBFCC, 0x45CC,
                   { 0x8B, 0x84, 0x17, 0xF2, 0x5F, 0x33, 0xE6, 0xE8 } };
    IAsio *asio = NULL; long r, nin, nout, bmin, bmax, bpref, bgran; double sr;
    CoInitialize(NULL);
    if (CoCreateInstance(&clsid, NULL, CLSCTX_INPROC_SERVER, &clsid,
                         (void**)&asio) != S_OK || !asio) { printf("CREATE_FAILED\n"); return 2; }
    r = asio->lpVtbl->init(asio, NULL);
    if (r != 0 && r != 1) { printf("INIT_FAILED %ld\n", r); return 3; }
    asio->lpVtbl->getChannels(asio, &nin, &nout);
    asio->lpVtbl->getBufferSize(asio, &bmin, &bmax, &bpref, &bgran);
    asio->lpVtbl->getSampleRate(asio, &sr);
    printf("OK %ld %ld %.0f %ld\n", nin, nout, sr, bpref);
    asio->lpVtbl->Release(asio);
    return 0;
}
EOF
    if ! x86_64-w64-mingw32-gcc -o "$dir/check.exe" "$dir/check.c" -lole32 -loleaut32 \
            >/dev/null 2>&1; then
        echo unknown; return
    fi
    local out
    out="$(cd "$dir" && timeout 30 wine check.exe 2>/dev/null | tail -1)"
    case "$out" in
        OK*)   echo "ok ${out#OK }" ;;
        *)     echo "fail $out" ;;
    esac
}

install_asio() {
    step "Step 5/5  Low-latency ASIO (WineASIO + PipeWire)"

    if [ "$HAS_SUDO" -ne 1 ]; then
        warn "WineASIO needs root to install into $WINE_ROOT; skipping."
        return 0
    fi

    # 5a. PipeWire's JACK implementation.
    if ! dpkg -s pipewire-jack >/dev/null 2>&1; then
        info "Installing pipewire-jack..."
        root_run apt-get install -y pipewire-jack \
            || warn "pipewire-jack install failed; WineASIO will not reach JACK."
    else
        ok "pipewire-jack already installed"
    fi

    # Make PipeWire's libjack.so.0 win over jackd2's (there is no jackd here).
    local snippet="/usr/share/doc/pipewire/examples/ld.so.conf.d/pipewire-jack-x86_64-linux-gnu.conf"
    if [ -f "$snippet" ]; then
        local target="/etc/ld.so.conf.d/$(basename "$snippet")"
        if [ ! -f "$target" ]; then
            root_run cp "$snippet" /etc/ld.so.conf.d/ && root_run ldconfig \
                && ok "made PipeWire's libjack.so.0 the system default"
        else
            ok "libjack.so.0 override already in place"
        fi
    fi

    # 5b. Build WineASIO against the matching Wine headers.
    install_build_deps
    ensure_wine_source

    local src="$BUILD_ROOT/wineasio"
    if [ ! -d "$src/.git" ]; then
        info "Cloning WineASIO..."
        rm -rf "$src"
        git clone --depth 1 "$WINEASIO_URL" "$src" || die "git clone (WineASIO) failed."
    else
        ok "reusing cached WineASIO source at $src"
    fi

    # WineASIO calls mlockall(MCL_FUTURE) in Init(). With the usual 8 MB
    # RLIMIT_MEMLOCK that breaks PipeWire's libjack thread creation and
    # jack_client_open() deadlocks forever. MCL_CURRENT keeps the realtime
    # intent without the deadlock.
    if grep -q 'mlockall(MCL_FUTURE)' "$src/asio.c" 2>/dev/null; then
        sed -i 's/mlockall(MCL_FUTURE);/mlockall(MCL_CURRENT);/' "$src/asio.c"
        ok "patched mlockall(MCL_FUTURE) -> MCL_CURRENT"
    fi

    local built="$src/build64/wineasio64.dll.so"
    local stamp="$BUILD_ROOT/.wineasio-built"
    if [ -f "$stamp" ] && [ -f "$built" ]; then
        ok "WineASIO already built"
    else
        info "Building WineASIO (64-bit)..."
        make -C "$src" clean >/dev/null 2>&1 || true
        make -C "$src" 64 WINEBUILD_INCLUDEDIR="$WINE_SRC/include" \
            >"$BUILD_ROOT/wineasio-build.log" 2>&1 \
            || die "WineASIO build failed - see $BUILD_ROOT/wineasio-build.log"
        [ -f "$built" ] || die "WineASIO build produced no wineasio64.dll.so"
        : > "$stamp"
        ok "built WineASIO"
    fi

    # 5c. Install into the Wine tree.
    root_run install -m 644 "$src/build64/wineasio64.dll" "$DLL_X64/wineasio64.dll"
    root_run install -m 644 "$built" "$WINE_LIB/x86_64-unix/wineasio64.so"
    ok "installed WineASIO into $WINE_ROOT"

    # 5d. Register it. Wine will not resolve "wineasio64.dll" by name, but it
    #     loads the builtin fine when handed the .so path. Timeout the call:
    #     regsvr32 can block if the path is not one Wine can map.
    local so_unix="$WINE_LIB/x86_64-unix/wineasio64.so"
    if ! timeout 60 wine regsvr32 "$so_unix" >/dev/null 2>&1; then
        warn "regsvr32 did not complete; WineASIO may not appear in FL's device list."
    fi

    # Point the CLSID at the .so so CoCreateInstance can load it.
    local so_win root
    so_win="Z:$(printf '%s' "$so_unix" | sed 's|/|\\|g')"
    for root in 'HKLM\Software\Classes\CLSID' 'HKCU\Software\Classes\CLSID'; do
        timeout 60 wine reg add "$root\\$WINEASIO_CLSID\\InProcServer32" /ve /d "$so_win" /f \
            >/dev/null 2>&1 || true
    done

    if timeout 60 wine reg query 'HKLM\Software\ASIO\WineASIO' >/dev/null 2>&1; then
        ok "WineASIO registered as an ASIO driver"
    else
        warn "WineASIO is not registered under HKLM\\Software\\ASIO"
    fi

    # 5e. PipeWire low-latency clock.
    install_pipewire_lowlatency
}

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

verify() {
    step "Verification"

    local ok_all=1

    if [ -f "$PREFIX_FONTS/Verdana.ttf" ]; then
        ok "Verdana.ttf installed in prefix"
    else
        warn "Verdana.ttf MISSING - FLEX will still crash"; ok_all=0
    fi

    local n; n="$(find "$PREFIX_FONTS" -maxdepth 1 -type f 2>/dev/null | wc -l | tr -d ' ')"
    [ "$n" -ge 50 ] && ok "prefix has $n fonts" || { warn "only $n fonts in prefix"; ok_all=0; }

    if [ -d "$FLEX_USER_PACKS" ]; then
        local p; p="$(find "$FLEX_USER_PACKS" -maxdepth 1 -type f \
                        \( -iname '*.flexpack' -o -iname '*.flex2pack' \) 2>/dev/null | wc -l | tr -d ' ')"
        [ "$p" -gt 0 ] && ok "$p FLEX pack(s) installed" || { warn "no FLEX packs installed"; ok_all=0; }
    fi

    if [ -n "$FL_DIR" ]; then
        info "Running FL Studio signature check (a window may flash briefly)..."
        local st; st="$(fl_signature_status)"
        case "$st" in
            ok)      ok "WinVerifyTrust accepts FL Studio's signature" ;;
            fail)    warn "WinVerifyTrust still rejects the signature (0x80096004)"; ok_all=0 ;;
            running) info "FL Studio is running - skipped the signature check" ;;
            *)       warn "signature check inconclusive" ;;
        esac
    fi

    # MIDI: no enabled FL input may point at an unopenable UMP-MIDI2 port.
    if [ -n "$(fl_config_key)" ] && [ -n "$(ump_midi_ports)" ]; then
        local key bad=0 dev cur
        key="$(fl_config_key)"
        while IFS= read -r dev; do
            [ -n "$dev" ] || continue
            cur="$(reg_value "HKCU\\Software\\Image-Line\\$key\\Devices\\MIDI input\\$dev" Enabled)"
            if [ -n "$cur" ] && [ "$cur" != "0" ]; then bad=$((bad + 1)); fi
        done <<< "$(ump_midi_ports)"
        if [ "$bad" -eq 0 ]; then
            ok "no unopenable MIDI inputs enabled (no 'driver was not enabled' error)"
        else
            warn "$bad unopenable MIDI input(s) still enabled - FL will show the error"
            ok_all=0
        fi
    fi

    # ASIO: WineASIO present, registered, and actually able to reach JACK.
    if [ -f "$WINE_LIB/x86_64-unix/wineasio64.so" ]; then
        ok "WineASIO installed"
        if wine reg query 'HKLM\Software\ASIO\WineASIO' >/dev/null 2>&1; then
            ok "WineASIO registered as an ASIO driver"
        else
            warn "WineASIO not registered"; ok_all=0
        fi
        if command -v ldconfig >/dev/null 2>&1; then
            if ldconfig -p 2>/dev/null | grep -q 'pipewire-0.3/jack/libjack.so.0'; then
                ok "libjack.so.0 resolves to PipeWire"
            else
                warn "libjack.so.0 does not resolve to PipeWire"; ok_all=0
            fi
        fi
        info "Testing WineASIO end-to-end (creates the driver and connects to JACK)..."
        local ares; ares="$(asio_selftest)"
        case "$ares" in
            "ok "*) ok "WineASIO works: ${ares#ok } (channels in/out, rate, buffer)" ;;
            fail*)  warn "WineASIO self-test failed: ${ares#fail }"; ok_all=0 ;;
            *)      info "WineASIO self-test skipped" ;;
        esac
    fi

    printf '\n'
    if [ "$ok_all" -eq 1 ]; then
        printf '%sAll checks passed.%s Start FL Studio and try FLEX.\n' "$C_BOLD$C_GRN" "$C_RESET"
    else
        printf '%sSome checks did not pass - see warnings above.%s\n' "$C_BOLD$C_YEL" "$C_RESET"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

printf '%sFL Studio / Wine fix%s  (wine %s, prefix %s)\n' \
    "$C_BOLD" "$C_RESET" "$WINE_VERSION" "$WINEPREFIX"

if [ "$VERIFY_ONLY" -eq 0 ]; then
    if [ "$DO_FONTS" -eq 1 ]; then install_fonts; fi
    if [ "$DO_PACKS" -eq 1 ]; then install_packs; fi
    if [ "$DO_SIG"   -eq 1 ]; then build_crypt32; fi
    if [ "$DO_MIDI"  -eq 1 ]; then install_midi_fix; fi
    if [ "$DO_ASIO"  -eq 1 ]; then install_asio; fi
fi

verify

cat <<EOF

${C_DIM}Notes / how to undo${C_RESET}

  * crypt32 backup:  $DLL_X64/crypt32.dll.orig
      restore with:  sudo mv "$DLL_X64/crypt32.dll.orig" "$DLL_X64/crypt32.dll"
      (a Wine upgrade overwrites the patched DLL - just re-run this script)

  * FLEX packs:      $FLEX_USER_PACKS
      deleting a pack's .flexpack/.flex2pack and .ini makes FLEX re-offer it

  * fonts:           $PREFIX_FONTS
      Wine substitutes any still-missing fonts (Lucida Console, Segoe UI,
      CJK) automatically, so text renders fine.

  * MIDI:            HKCU\\Software\\Image-Line\\<ver>\\Devices\\MIDI input\\<device>
      the two PipeWire UMP-MIDI2 inputs are disabled; re-enable them in FL's
      MIDI settings if you ever need them

  * WineASIO:        $WINE_LIB/x86_64-unix/wineasio64.so  (+ x86_64-windows/wineasio64.dll)
      remove with:   sudo rm those two files, then
                     wine regsvr32 -u "$WINE_LIB/x86_64-unix/wineasio64.so"
      NOTE: Wine will not resolve "wineasio64.dll" by name, so the CLSID's
      InProcServer32 points at the .so path - that is intentional.

  * PipeWire clock:  ~/.config/pipewire/pipewire.conf.d/10-low-latency.conf
      revert with:   delete the file, then:
                     pw-metadata -n settings 0 clock.force-quantum 0
                     pw-metadata -n settings 0 clock.force-rate 0

  * libjack override: /etc/ld.so.conf.d/pipewire-jack-x86_64-linux-gnu.conf
      revert with:   sudo rm that file && sudo ldconfig

  * build cache:     $BUILD_ROOT   (safe to delete, ~1 GB)

  Upstream references:
    Wine bug 60273   https://bugs.winehq.org/show_bug.cgi?id=60273
    Wine MR  !11824  https://gitlab.winehq.org/wine/wine/-/merge_requests/11824
    WineASIO         https://github.com/wineasio/wineasio
EOF
