# HANDOFF.md — Project DSWUnity (iOS External ESP Overlay)

This document is a comprehensive handoff guide for **Claude** (or any subsequent AI assistant) to take over and continue working on the **DSWUnity** project without requiring the user to re-explain project history, architecture, or status.

---

## 📌 1. Project Overview & Identity

- **Project Name:** DSWUnity (formerly Cofi / External-FF)
- **App Display Name:** `DSWUnity`
- **Bundle Identifier:** `Ds.Dswunity.Esp`
- **Target OS:** iOS / iPadOS 17.0 – 18.7.1 & 26.0 – 26.0.1 (arm64 / arm64e, A12–A17, M1–M3, A16 T8110 verified)
- **Primary Game Target:** Free Fire (Current Offsets: Version `1.132.1`)
- **GitHub Repository:** `tuananh404/luachuasv` (Branch: `main`)
- **Support / Contact Link:** `https://t.me/duydzne` (`@duydzne`)

---

## 📁 2. Workspace File System Layout

- **`/storage/emulated/0/DarkSwordFreeFire/freefiresv/`**: The main Git repository root containing all source code, Xcode project (`ds.xcodeproj`), and GitHub Actions workflow (`.github/workflows/build.yml`).
- **`/storage/emulated/0/DarkSwordFreeFire/Cofi-1.0.ipa`**: The latest successfully compiled and packaged unsigned IPA artifact (7.0 MB).
- **`/storage/emulated/0/DarkSwordFreeFire/DarkSwordFreeFire.zip`** & **`DSWUnity_Project.zip`**: Full archive containing source code, offsets, artifacts, and dumper files.
- **`/storage/emulated/0/DarkSwordFreeFire/ffdump132/`**: Official IL2CPP dump files for Free Fire v1.132.1 (`dump.cs`, `script.json`, `il2cpp.h`).
- **`/storage/emulated/0/DarkSwordFreeFire/new.jpg`**: Source image used for generating the app icon set.
- **`/storage/emulated/0/debugdsw/`**: Device test execution logs (`no.log` for iOS 17.5.1 A13, `ok.log` for iOS 18.0 / 26.0 A16).

---

## 🏗️ 3. Architecture & Execution Pipeline

DSWUnity is an external iOS overlay running completely outside the game process without repackaging or injecting dylibs into the game.

### Execution Chain:
1. **Kernel Exploit (`kexploit/kexploit_opa334.m`):** Acquires Kernel R/W via a TCP-socket race & `icmp6filter` memory overwrite.
2. **XPF Kernel Patchfinder (`kpf/patchfinder.m`):** Uses `/Cofi/XPF/output/ios/libxpf.dylib` to dynamically find kernel symbols (`allproc`, `ptov_table`, `gPhysBase`, etc.) in <0.2s.
3. **Sandbox Escape (`utils/sandbox.m`):** Patches sandbox extensions to grant cross-process memory access.
4. **RemoteCall / SpringBoard Channel (`TaskRop/RemoteCall.m`):** Injects EXC_GUARD thread hijack into `SpringBoard` (PID ~3738) to host a passthrough overlay window (`windowLevel = 10000001`).
5. **Memory Provider (`DarkSwordMemoryProvider.m` + `Core/PhantomMemory.m`):** Reads game process memory (`UnityFramework` base address, roster, camera data) via kernel read.
6. **Camera Projection Engine (`Core/UnityMath.mm`):** Dynamically scans native C++ Camera objects (`0x480` bytes scan window) to extract perspective projection matrix and perform WorldToScreen projection.
7. **ESP Drawing Engine (`drawing_view/esp.mm` + `ESP/ESPDrawOverlay.m`):** Renders 2D Bounding Boxes, Tracelines, Health Bars, Nicknames, Distance Meters, and Enemy Counter via `CAShapeLayer`.
8. **Aim Engine (`Core/AimAssistEngine.mm`):** Runs on the same worker tick as the ESP builder, reuses the calibrated projection to pick the best target inside the aim FOV, and steers the local player's aim rotation via kernel writes (`RemoteWriteDomain::Aim`). The overlay-facing FOV circle + lock line travel inside the `ESPDrawPacket`.

---

## 🛠️ 4. Summary of Recent Fixes & Modifications Applied

0. **Aim Engine (VIP Standard) Re-Added — 2026-09-20:**
   - New `Cofi/Core/AimAssistEngine.h/.mm` — full VIP-standard aimbot port:
     FOV-window target scan (3× drawn radius), lock persistence (2 lost
     frames), PhysicalCCT velocity + weapon-profile bullet prediction,
     Slerp quaternion steering, AuxAimResetTime zeroing, ±89° pitch limits,
     single-shot snap (AWM/M590), and auto-fire via `TrySetDataUInt16`.
   - Write transport enabled: `DarkSwordMemoryProvider.writeMemory:from:size:`
     maps game pages through `vm_map_remote_page` (READ|WRITE) into a dedicated
     24-slot writable cache; `phantom_write_bytes` + `MemoryUtils._write` gate
     every write behind `RemoteWriteDomain::Aim` (armed only while Aimbot is
     on, fails closed otherwise).
   - Aim offsets added to `GameOffsets.h` (dump-verified): AuxAimResetTime
     0xE38, MinAngleX 0xE3C, MaxAngleX 0xE40, PhysicalCCT 0x268 / Velocity
     0x17C, Inventory chain 0x740→0xA0→0x768 with weapon fields 0x1F4/0x1F8/
     0x208/0x27C.
   - `ESPDrawPacket` extended (magic bumped to `0x45535033` "ESP3") with
     `showFov`, `fovRadius`, `aimHasTarget`, `aimTargetPoint`; the SpringBoard
     overlay renders the VIP-mint FOV circle (`gFovLayer`) and aim lock line
     (`gAimLineLayer`) purely from the packet.
   - Settings UI: new "Aim Engine (VIP)" section (Aimbot, FOV circle, lock
     line, FOV radius slider 5–500, Aim speed slider 100–2000, Aim position,
     Trigger mode, ignore bot/knocked, visibility check) plus a reusable
     SliderRow control. In-game ESP menu gained the same `renew.aim*` keys.
   - Deliberate deltas vs the reference build: prediction uses the LOCAL
     player's weapon profile; AimSpeed scales the Slerp factor (1000 ==
     reference constants 0.97/0.92/0.85).

1. **GitHub Actions CI/CD Fixes:**
   - Installed `ldid` via `brew install ldid` in workflow.
   - Added manual copy step `cp Cofi/XPF/output/ios/libxpf.dylib $APP_PATH/libxpf.dylib` to prevent missing dylib launch crash.
   - Preserved git symlink `Cofi/XPF/external/ChOma/include/choma` with mode `120000`.

2. **Game Offsets Updated to v1.132.1:**
   - `Cofi/Core/GameOffsets.h` updated with values verified against `ffdump132`:
     - `GameFacadeTypeInfo` = `0xBB46A50ULL`
     - `GameVarDefTypeInfo` = `0xBB46AF8ULL`
     - `PlayerHeadNode` = `0x6A0ULL`
     - `PlayerAimRotation` = `0x614ULL`

3. **Complete UI Redesign (DSWUnity):**
   - Redesigned app theme to Cyan (`#06B6D4`) & Deep Slate (`#0F172A`) gaming aesthetic in `UITheme.h` and `SettingsViewController.m`.
   - Removed all unneeded non-ESP functions (Aim, FOV, No Recoil, Ghost, Fast Fire, Fast Reload, Fast Medikit, Fast Run).
   - Focused strictly on pure ESP features: Tracelines, 2D Box, Health Bar, Nickname, Distance, Player Counter, Refresh Rate (1–30 Hz).
   - Set Telegram Support Contact to: `https://t.me/duydzne` (`@duydzne`).

4. **App Icon Set Update:**
   - Converted `new.jpg` into all required iOS/iPadOS/macOS icon sizes in `Cofi/Assets.xcassets/AppIcon.appiconset/`.

5. **Anti-Screen Capture Removal:**
   - Completely removed `setDisableUpdateMask:0x10` and `kSettingsHideScreenCapture` from codebase because `setDisableUpdateMask` caused `CALayer` rendering to become hidden on iOS 26.

6. **iOS 26 Camera Matrix Projection Optimization (`Core/UnityMath.mm`):**
   - Expanded camera native C++ memory scan window `kCameraScanSize` from `0x240` to `0x480` bytes to cover Unity Engine 2023/2024 matrix offsets on iOS 26.
   - Lowered calibration score threshold `kLockedScoreThreshold` from `18.0f` to `4.0f` for instant matrix locking.
   - Added instant fallback projection so ESP draws from frame 1 without delay.

7. **Enemy Counter Indicator (`ESP/ESPDrawOverlay.m`):**
   - Updated `esp_draw_overlay_apply_counter`:
     - When ESP is active (`gDrawState == ESPDrawOverlayStateRunning`), the top-center counter label **always displays `--`** as an active status indicator.
     - When in-game with valid target data, it automatically displays the real numeric enemy count (e.g. `1`, `2`, `3`...).

---

## 💡 5. Crucial Instructions for the Next Assistant (Claude)

1. **Git Symlink Protection on Android Filesystem:**
   - Android filesystems convert symlinks to plain text files. Before running `git commit`, ALWAYS execute:
     ```bash
     printf '../src' | git hash-object -w --stdin
     git update-index --add --cacheinfo 120000,5cd551cf2693e4b4f65d7954ec621454c2b20326,Cofi/XPF/external/ChOma/include/choma
     ```
     Failure to do so will break the `ChOma` C++ header include during CI build!

2. **Automated CI/CD Workflow:**
   - Pushing to `main` branch automatically triggers `.github/workflows/build.yml` on GitHub Actions, which builds the IPA, uploads artifact zip, and creates a Release on GitHub (`tuananh404/luachuasv`).

3. **Key Header Files:**
   - `Cofi/Core/GameOffsets.h` — Offsets for Free Fire (ESP + Aim).
   - `Cofi/Core/UnityMath.mm` — Matrix calculation & WorldToScreen.
   - `Cofi/Core/AimAssistEngine.mm` — VIP-standard aim engine.
   - `Cofi/ESP/ESPDrawOverlay.m` — Overlay window rendering, FOV circle, counter label.
   - `Cofi/SettingsViewController.m` — DSWUnity main dashboard & settings.

---
*Generated & Handed off on 2026-09-19.*
