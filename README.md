# TouchBar Guard (`touchbar_guard`)

[![macOS](https://img.shields.io/badge/macOS-15%2B%20(tested)-blue.svg)](https://apple.com)
[![Architecture](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-orange.svg)](https://apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Language](https://img.shields.io/badge/language-Objective--C-green.svg)](src/touchbar_guard.m)

A macOS daemon that prevents ghost touches on MacBook Pros with damaged Touch Bars and eliminates `_dmaReferences overflow` kernel panics.

Documentation:
- 🇺🇸 [English Documentation](README.md) (This file)
- 🇺🇦 [Українська документація](README.uk.md)

---

## Background

On MacBook Pro models with a Touch Bar:
- **Apple Silicon:** MacBook Pro (13", M1, 2020 — `MacBookPro17,1`), MacBook Pro (13", M2, 2022 — `Mac14,7`).
- **Intel (Touch Bar models):** MacBook Pro 13" with Touch Bar (2016–2020) and MacBook Pro 15" (2016–2019). *(Models without a Touch Bar, such as the 13" 2016–2017 two-port variant, are unaffected).*

Over time, two hardware failures frequently coincide:
1. The Touch Bar OLED panel fails (remains pitch black), but the capacitive digitizer layer remains powered and generates erratic phantom touches.
2. The lid-angle sensor (Hall effect sensor) fails, preventing the laptop from sleeping when closed.

This causes two critical issues:
- **Phantom Input:** Random touches wake the display, turn the volume to maximum, change brightness, or trigger Siri while the laptop is locked or carried in a backpack.
- **Kernel Panic (`_dmaReferences overflow`):** When the display dims or locks, `TouchBarServer` enters an empty drawable queue loop (`SLSHMDGetDrawable - unexpected server error response: 1000`) at ~70 Hz. In `AppleMobileDispH13G-DFR`, unacknowledged DMA frame transactions leak a reference counter in XNU's `IOMemoryDescriptor.cpp`. Because `_dmaReferences` is a signed 16-bit integer, after exactly 32,767 leaked frames (~8–16 hours of idling), it overflows and crashes macOS:
  ```text
  panic(cpu 1 caller 0xfffffe00489a1ee4): _dmaReferences overflow @IOMemoryDescriptor.cpp:5086
  Kernel Extensions in backtrace:
     com.apple.driver.AppleMobileDispH13G-DFR
  ```

> **Compatibility Note:** Verified on a MacBook Pro (13", M1, 2020) running macOS 15+. Older macOS releases (12–14) and Intel-based Macs have not been tested. Suspending `ControlStrip` is likely to work similarly on Intel hardware, but display drivers differ and the DMA reference count panic was specifically observed on Apple Silicon.

---

## How It Works

`touchbar_guard` provides a dual-layer defense:

### 1. Phantom Touch Shield (`ControlStrip`)
- **On lock or sleep:** The daemon sends `SIGSTOP` to `ControlStrip`. Touch input on the bar no longer adjusts volume, brightness, or controls.
- **On unlock or wake:** The daemon sends `SIGCONT` to `ControlStrip`, instantly restoring touch controls.

### 2. DMA Watchdog (`TouchBarServer`)
- Halting `TouchBarServer` with `SIGSTOP` is dangerous because it stalls DMA frame processing and causes a panic within minutes.
- However, terminating `TouchBarServer` with `SIGKILL` causes `launchd` to immediately respawn it (< 50 ms) with a fresh SkyLight session and cleared DMA queue.
- `touchbar_guard` acts as a watchdog: it recycles `TouchBarServer` on lock, unlock, and on a 30-minute background timer. This resets the leaked reference count to 0, ensuring `_dmaReferences` never approaches the 32,767 threshold.

Events are detected via Darwin BSD notifications (`com.apple.sessionagent.*`, `com.apple.mobile.keybagd.lock_status`), IOKit power/display notifications (`IORegisterForSystemPower`, `IODisplayWrangler`), Cocoa notifications (`NSWorkspace`, `NSDistributedNotificationCenter`), and a GCD dispatch timer.

---

## Limitations

- The daemon traps exit signals (`SIGTERM`, `SIGINT`, `SIGQUIT`) and automatically resumes `ControlStrip` before terminating. It also verifies lock state and resumes `ControlStrip` on launch if the screen is unlocked.
- `ControlStrip` will only remain stopped if the daemon crashes unexpectedly or is terminated with `kill -9` (`SIGKILL`) while the screen is locked.
- If this occurs, `ControlStrip` can be manually resumed with:
  ```bash
  killall -CONT ControlStrip
  ```
- `TouchBarServer` recycling requires root privileges (which the `launchd` daemon has by default). Manual recycling with `--recycle` requires `sudo`.

---

## Repository Structure

```text
touchbar-guard/
├── Makefile                                # Build, install, uninstall, status
├── install.sh                              # Installation script
├── uninstall.sh                            # Uninstallation script
├── LICENSE                                 # MIT License
├── README.md                               # English documentation
├── README.uk.md                            # Ukrainian documentation
├── launchd/
│   └── com.github.touchbar_guard.plist     # launchd daemon configuration
└── src/
    └── touchbar_guard.m                    # Objective-C source
```

---

## Installation

### Option 1: Installer Script

```bash
git clone https://github.com/g-autof/touchbar-guard.git
cd touchbar-guard
sudo ./install.sh
```

### Option 2: Using `make`

```bash
cd touchbar-guard
make universal
sudo make install
```

The script builds a universal binary (`arm64` + `x86_64`), installs it to `/usr/local/bin/touchbar_guard`, copies `/Library/LaunchDaemons/com.github.touchbar_guard.plist`, and registers the service with `launchd`. Logs are written to `/var/log/touchbar_guard.log`.

---

## Status & CLI Commands

Check daemon, `ControlStrip`, and `TouchBarServer` status:

```bash
touchbar_guard --status
```

Flags:
```bash
touchbar_guard --status    # Show PID and state of touchbar_guard, ControlStrip, and TouchBarServer
touchbar_guard --freeze    # Manually freeze ControlStrip (SIGSTOP)
touchbar_guard --thaw      # Manually thaw ControlStrip (SIGCONT)
touchbar_guard --recycle   # Manually recycle TouchBarServer (SIGKILL, requires sudo)
touchbar_guard -f          # Run daemon in foreground (debugging)
```

Running `make test` builds the binary, tests CLI flags (`--help`, `--version`, `--status`), validates rejection of invalid arguments, and executes a freeze/thaw test cycle.

### Logs

```bash
tail -f /var/log/touchbar_guard.log
# or
make logs
```

---

## Uninstallation

Stop the service, remove installed files, and ensure `ControlStrip` is thawed:

```bash
sudo ./uninstall.sh
# or
sudo make uninstall
```

---

## License

[MIT](LICENSE)
