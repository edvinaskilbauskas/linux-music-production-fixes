# linux-fixes

Shell scripts that make **Windows audio software work properly under Wine on Linux**.

Every script here targets one specific, reproducible problem that a normal Wine install
cannot solve on its own — a crash, a missing feature, or a GUI that renders incorrectly —
and fixes it with the smallest change that actually works. Each one is idempotent, keeps
backups, verifies its own result, and prints notes on how to undo everything it did.

Tested on Ubuntu 26.04 with Wine 11.0. Nothing here is distro-specific beyond using
`apt`/`sudo` for the steps that need root.

## The scripts

| Script | Application | What it fixes |
|---|---|---|
| [`fl-studio-linux-fix.sh`](fl-studio-linux-fix.sh) | FL Studio 2026 | FLEX crashes, missing FLEX packs, "validity of the program could not be verified", MIDI driver errors, high-latency audio |
| [`serum2-linux-fix.sh`](serum2-linux-fix.sh) | Xfer Serum 2 (VST3) | The plugin editor renders garbled/black and does not recover correctly after the window is moved or resized |
| [`splice-linux-setup.sh`](splice-linux-setup.sh) | Splice Desktop | The Windows download cannot install at all under Wine, and the UI shows no text |

## Requirements

- Linux on x86_64, with **Wine already installed and on `PATH`**
- `bash`, `python3`, and `sudo` (the scripts call `sudo` themselves — do **not** run them as root)
- A network connection for the steps that download things
- For the scripts that build Wine components: the usual build tools and dev libraries,
  which the scripts install for you via `apt`

The scripts assume an existing Wine prefix (`~/.wine` by default, `~/.splice-wine` for
Splice). Override with `WINEPREFIX` / `SPLICE_PREFIX` where supported.

## Quick start

```bash
git clone https://github.com/edvinaskilbauskas/linux-fixes.git
cd linux-fixes
```

**FL Studio**

```bash
./fl-studio-linux-fix.sh            # apply every fix
./fl-studio-linux-fix.sh --verify-only
```

**Serum 2** (builds a patched Wine, so it takes a while the first time)

```bash
./serum2-linux-fix.sh               # build + install + configure
./serum2-linux-fix.sh --verify-only
```

**Splice Desktop**

```bash
./splice-linux-setup.sh
./splice-linux-setup.sh --verify-only
```

Every script supports `--help`.

## What each script does

### `fl-studio-linux-fix.sh`

Addresses five independent problems:

1. **Fonts.** FL Studio and FLEX open font files by absolute path
   (`C:\windows\Fonts\Verdana.ttf`). A prefix with no fonts makes those opens fail, and
   FLEX does not null-check the result and crashes. The script installs the MS core fonts
   plus FL's own bundled fonts into the prefix.

2. **FLEX packs.** FLEX reads its sound packs from the user data folder, but FL Studio's
   installer stages them inside the install directory, so FLEX reports them as "not
   installed" and tries (and fails) to re-download. The script copies the staged packs
   where FLEX looks for them.

3. **Signature verification.** FL Studio 2026 binaries are signed with PKCS#7
   authenticated attributes in non-canonical DER order. Wine re-sorts them before hashing
   and rejects a valid signature with `TRUST_E_CERT_SIGNATURE` (`0x80096004`), so FL
   refuses to start. The script builds a patched `crypt32.dll` from matching Wine sources
   and installs just that DLL, with a backup. See
   [WineHQ bug 60273](https://bugs.winehq.org/show_bug.cgi?id=60273).

4. **MIDI.** PipeWire advertises its MIDI bridge as ALSA "UMP MIDI2" user ports, which
   Wine's MIDI input cannot open; FL reports "The driver was not enabled." on every
   launch. The script disables those specific devices in FL's MIDI config.

5. **Low-latency audio.** FL only sees "FL Studio ASIO" (a WASAPI wrapper that goes
   through Wine's PulseAudio path and adds tens of milliseconds). Vendor ASIO drivers
   cannot work under Wine, so the script installs
   [WineASIO](https://github.com/wineasio/wineasio) — an ASIO driver that bridges to JACK,
   which PipeWire serves — registers it, and pins PipeWire to a small quantum.

### `serum2-linux-fix.sh`

Serum 2's editor is a VSTGUI window drawn through **Direct2D**, presented through
**DirectComposition**, with D3D11 underneath. Stock Wine's Direct2D is a partial
implementation and its `dcomp` is a stub. The only stock-Wine workaround is Serum's own
"Disable DirectComposition" switch, which drops the plugin to a plain GDI/HWND path — and
in Wine that path leaves the plugin's window as an offscreen-redirected X11 child that
never gets composited, so the editor is stale or scrambled until something forces a
repaint.

The fix is [giang17's `d2d1-dcomp` patch series](https://github.com/giang17/wine), which
implements the D2D1 geometry pipeline, DirectComposition visual trees, the winex11
client-surface handling for `ID2D1HwndRenderTarget` windows, and the wined3d GL present.

That patch series touches `win32u`, `user32`, `ntdll`, the wineserver, `wined3d`,
`winex11.drv`, `d2d1`, `dcomp`, `dxgi` and `dwrite`, so it cannot be shipped as a handful
of replacement DLLs — it has to be a full Wine build. The script therefore:

- builds the fork into its own prefix (`/opt/wine-d2d1`), leaving your distro Wine alone;
- refreshes your existing Wine prefix so it actually loads the patched DLLs (Wine keeps
  its own copies of builtins inside the prefix, and the loader reads *those*);
- copies WineASIO into the patched Wine and re-points its CLSID;
- enables Serum's DirectComposition path, which is both faster and the path the patches
  were developed against;
- installs a launcher (`~/.local/bin/flstudio`) and an apps-menu entry.

Two things worth knowing:

- **Do not install DXVK into that prefix.** The branch's DirectComposition and
  composition-swapchain handling live in Wine's `dxgi`/`d3d11`, which DXVK replaces;
  mixing the two is unsupported.
- A Wine prefix holds **one** set of builtins. After this script runs, that prefix is
  running the patched Wine. If you want the stock Wine back for other applications, give
  those their own prefix.

Serum 2 is 64-bit (and so is FL Studio 2026), so a 64-bit-only Wine is built by default.
Pass `--both-archs` if you also need 32-bit plugins.

### `splice-linux-setup.sh`

Splice has no Linux client, and the download offered at `desktop.splice.com` is not a
normal installer: it is a Conveyor/Hydraulic MSIX bootstrapper that installs through the
Windows AppX/MSIX deployment APIs. Wine has no AppX/MSIX support, so that executable can
never work under Wine. This script does what the bootstrapper would have done, minus the
deployment step: it fetches the `.msix` (which is just a ZIP), unpacks the application
payload, and runs `Splice.exe` directly.

Two Wine-specific problems are handled:

1. **Fonts.** Splice is an Electron app and renders text through DirectWrite, which only
   sees the font families registered in Wine's font registry. The MS core fonts are not
   registered by default, and missing families do not fall back — they resolve to a
   zero-width font, so the UI shows layout but no text. The script registers those faces.

2. **Node mode.** If `ELECTRON_RUN_AS_NODE` is set in the environment, `Splice.exe` starts
   as a Node process instead of a browser process, fails to load its main script, and
   exits silently with no window. The launcher unsets it.

Splice gets its own Wine prefix (`~/.splice-wine`) so it cannot be affected by, or affect,
a DAW prefix.

## Notes and caveats

- These scripts modify Wine installations and prefixes. Every change is backed up and the
  undo steps are printed at the end of each run.
- A Wine upgrade overwrites patched DLLs installed into the Wine tree. Re-run the
  relevant script afterwards.
- Wine prefixes are not isolated per application. Where a script needs isolation (Splice),
  it creates its own prefix.
- These are community workarounds for software that does not officially support Linux.
  Expect to re-run them occasionally after updates to Wine or the applications.

## Credits

- The Serum 2 fix builds [giang17/wine](https://github.com/giang17/wine) — the Direct2D
  and DirectComposition work that makes these plugins usable under Wine at all.
- [WineASIO](https://github.com/wineasio/wineasio) provides the ASIO-to-JACK bridge.
- [WineHQ](https://www.winehq.org/) and the Wine contributors.

## Disclaimer

Not affiliated with or endorsed by Image-Line, Xfer Records, Splice, or the Wine project.
All product names and trademarks are the property of their respective owners. These
scripts only make software you already own run correctly; they do not include, crack, or
bypass licensing for any application.

## Contributing

Issues and pull requests are welcome — especially reports of these fixes working (or not)
on other distributions, Wine versions, or GPUs. If you add a script, please keep the same
conventions: idempotent, `--verify-only` and `--help` support, backups for anything
overwritten, and a clear undo note at the end.

## License

[MIT](LICENSE)
