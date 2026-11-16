# TouchBar Guard (`touchbar_guard`)

[![macOS](https://img.shields.io/badge/platform-macOS%2012%2B-blue.svg)](https://apple.com)
[![Architecture](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-orange.svg)](https://apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Language](https://img.shields.io/badge/language-Objective--C-green.svg)](src/touchbar_guard.m)

A production-grade, low-overhead macOS daemon designed to neutralize **phantom touches** on MacBook Pro models with aging, broken, or dead Touch Bars without inducing kernel panics.

Available documentation:
- 🇺🇸 [English Documentation](README.md) (This file)
- 🇺🇦 [Українська документація](README.uk.md)

---

## The Hardware Problem

On MacBook Pro models equipped with the OLED Touch Bar:
- **Apple Silicon:** MacBook Pro (13-inch, M1, 2020 — `MacBookPro17,1`), MacBook Pro (13-inch, M2, 2022 — `MacBookPro14,7`)
- **Intel:** MacBook Pro (13-inch, 15-inch, 16-inch, 2016–2020)

As hardware ages, the OLED display panel inside the Touch Bar frequently dies and remains completely black. However, its capacitive touch digitizer often remains fully energized and begins generating erratic **phantom touches**.

When this occurs alongside a worn or broken **Hall effect lid angle sensor** (a frequent secondary failure where closing the lid fails to put the laptop to sleep):
- The digitizer continuously wakes up the display when locked.
- Random ghost touches rapidly fluctuate screen brightness and volume.
- Unintended Siri activations and lock screen interruptions occur.
- Severe overheating and rapid battery depletion happen inside bags and backpacks.

---

## The Flaw in Existing Workarounds: Kernel Panic

Common community scripts (widely shared on forums and Reddit) typically recommend freezing the Touch Bar using `SIGSTOP` on both services:

```bash
# ⚠️ DANGEROUS WORKAROUND - CAUSES KERNEL PANICS ON MODERN MACOS
kill -STOP $(pgrep TouchBarServer) $(pgrep ControlStrip)
```

On modern macOS versions (macOS 14 Sonoma, macOS 15 Sequoia, and newer), suspending `TouchBarServer` causes an inevitable, catastrophic **Kernel Panic**:

```text
panic(cpu 1 caller 0xfffffe001ec4cf3c): _dmaReferences overflow @IOMemoryDescriptor.cpp:5086
Debugger message: panic
Backtrace (CPU 1), panicked thread: 0xfffffe1ffc774640:
...
Kernel Extensions in backtrace:
   com.apple.driver.AppleMobileDispH13G-DFR
```

### Technical Root Cause:
1. **DFR Framebuffer Driver:** Apple Silicon and modern T2/DFR architectures use kernel drivers such as `com.apple.driver.AppleMobileDispH13G-DFR` to manage display transactions for the Display Function Row.
2. **Display Server Client:** `TouchBarServer` acts as the direct user-space display server client for this hardware driver.
3. **Stalled DMA Handshake:** When `TouchBarServer` is halted with `SIGSTOP`, its Mach message loop halts. The DFR driver continues submitting frame transfers, but the suspended display client never completes the DMA transaction acknowledgement.
4. **Reference Count Overflow:** For every unacknowledged frame, the driver increments `_dmaReferences` inside `IOMemoryDescriptor`. In XNU, `_dmaReferences` is represented as a signed 16-bit integer (maximum value: `32,767`).
5. **System Crash:** After ~32,767 cycles, `_dmaReferences` overflows, triggering a fatal assertion check in the kernel at line `5086` of `IOMemoryDescriptor.cpp` and immediately rebooting the Mac.

---

## The Surgical Solution

`touchbar_guard` implements a precise, tested approach:

> **Rule:** NEVER send signals to `TouchBarServer`! Target ONLY `ControlStrip`.

```text
┌────────────────────────────────────────────────────────┐
│                   Lock / Sleep Event                   │
└───────────────────────────┬────────────────────────────┘
                            │
              ┌─────────────▼─────────────┐
              │  touchbar_guard Daemon   │
              └─────────────┬─────────────┘
                            │
              ┌─────────────▼─────────────┐
              │   SIGSTOP -> ControlStrip │
              └─────────────┬─────────────┘
                            │
       ┌────────────────────┴────────────────────┐
       ▼                                         ▼
┌──────────────────────────────┐   ┌──────────────────────────────┐
│  ControlStrip (Frozen)       │   │ TouchBarServer (Active)      │
│  - No UI reaction to touches │   │ - Frame transactions normal  │
│  - No volume / brightness    │   │ - DMA queue clears normally  │
│  - Ghost taps ignored        │   │ - ZERO kernel leaks / panics │
└──────────────────────────────┘   └──────────────────────────────┘
```

1. **`ControlStrip` (`/System/Library/CoreServices/ControlStrip.app`)** is strictly a user-space UI process responsible for rendering buttons, the volume slider, brightness adjustments, and Siri.
2. Freezing `ControlStrip` with `SIGSTOP` completely disables UI touch event handlers. Phantom digitizer touches produce **zero effect**.
3. Meanwhile, `TouchBarServer` continues its normal IPC loop with `AppleMobileDispH13G-DFR`, completely avoiding DMA stalls or memory descriptor overflows.
4. Upon unlock or display wake, `touchbar_guard` issues `SIGCONT` to `ControlStrip`, instantly re-enabling controls with zero latency.

---

## Multi-Layer Event Detection

To ensure zero phantom touch wakeups under all lock, sleep, and session-switch states, `touchbar_guard` listens across four independent system subsystems:

1. **Darwin BSD Notifications (`notify.h`):**
   - Lock: `com.apple.sessionagent.screenIsLocked`, `com.apple.sessionagent.screenLockUIIsShown`, `com.apple.sessionagent.shieldWindowRaised`, `com.apple.mobile.keybagd.lock_status`, `com.apple.screensaver.didstart`.
   - Unlock: `com.apple.sessionagent.screenIsUnlocked`, `com.apple.sessionagent.screenLockUIIsHidden`, `com.apple.sessionagent.shieldWindowLowered`, `com.apple.screensaver.didstop`.
2. **Cocoa Distributed Notifications (`NSDistributedNotificationCenter`):**
   - `com.apple.screenIsLocked`
   - `com.apple.screenIsUnlocked`
3. **IOKit Power & Display Interest Notifications (`IOPMLib.h`, `IOMessage.h`):**
   - `IORegisterForSystemPower`: intercepts `kIOMessageSystemWillSleep`, `kIOMessageSystemHasPoweredOn`, and `kIOMessageCanSystemSleep`.
   - `IODisplayWrangler`: intercepts `kIOMessageDeviceWillPowerOff` and `kIOMessageDeviceHasPoweredOn`.
4. **AppKit `NSWorkspace` Notifications:**
   - `NSWorkspaceScreensDidSleepNotification` & `NSWorkspaceScreensDidWakeNotification`
   - `NSWorkspaceWillSleepNotification` & `NSWorkspaceDidWakeNotification`
   - `NSWorkspaceSessionDidResignActiveNotification` & `NSWorkspaceSessionDidBecomeActiveNotification`

---

## Repository Structure

```text
touchbar-guard/
├── Makefile                                # Compilation, install, uninstall, status, logs
├── install.sh                              # Automated installer with privilege elevation
├── uninstall.sh                            # Clean uninstaller with process thaw guarantee
├── LICENSE                                 # MIT License
├── README.md                               # English documentation
├── README.uk.md                            # Ukrainian documentation
├── launchd/
│   ├── com.yustyna.touchbar_guard.plist    # Production launchd service manifest
│   └── com.github.touchbar_guard.plist     # Neutral vendor launchd manifest
└── src/
    └── touchbar_guard.m                    # Core Objective-C daemon implementation
```

---

## Quick Start & Installation

### Option 1: Automated Installer (Recommended)

```bash
git clone https://github.com/yustyna/touchbar-guard.git
cd touchbar-guard
sudo ./install.sh
```

### Option 2: Using `make`

```bash
cd touchbar-guard
make universal
sudo make install
```

The installer performs the following actions:
- Compiles a universal Mach-O binary (`arm64` + `x86_64`).
- Installs the binary to `/usr/local/bin/touchbar_guard`.
- Configures `/Library/LaunchDaemons/com.yustyna.touchbar_guard.plist` with `RunAtLoad` and `KeepAlive`.
- Registers the service via `launchctl bootstrap`.
- Sets line-buffered logging to `/var/log/touchbar_guard.log`.

---

## Verification & Status

To verify daemon status and confirm whether `ControlStrip` is responsive or frozen:

```bash
touchbar_guard --status
```

Example output:
```text
=== TouchBarGuard Status ===
  • Process: touchbar_guard (PID: 1245)
    Path:   /usr/local/bin/touchbar_guard
    Status: SSLEEP (sleeping/responsive)
=== ControlStrip Status ===
  • Process: ControlStrip (PID: 4215)
    Path:   /System/Library/CoreServices/ControlStrip.app/Contents/MacOS/ControlStrip
    Status: SRUN (running)
```

### Viewing Live Logs

```bash
make logs
# Or directly:
tail -f /var/log/touchbar_guard.log
```

Log entry examples:
```text
[2026-11-16 23:15:02] [TouchBarGuard] BLOCKED Touch Bar [SIGSTOP -> ControlStrip (instances: 1)] (Reason: Screen lock UI shown)
[2026-11-16 23:15:18] [TouchBarGuard] UNBLOCKED Touch Bar [SIGCONT -> ControlStrip (instances: 1)] (Reason: Session screen unlocked)
```

---

## Uninstallation

To cleanly stop the daemon, remove installed binaries and launchd configurations, and ensure `ControlStrip` is unfrozen:

```bash
sudo ./uninstall.sh
# Or via make:
sudo make uninstall
```

---

## License

This project is licensed under the [MIT License](LICENSE).
