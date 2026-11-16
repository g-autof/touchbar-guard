# TouchBar Guard (`touchbar_guard`)

[![macOS](https://img.shields.io/badge/platform-macOS%2012%2B-blue.svg)](https://apple.com)
[![Architecture](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-orange.svg)](https://apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Language](https://img.shields.io/badge/language-Objective--C-green.svg)](src/touchbar_guard.m)

A macOS daemon that disables Touch Bar touch handling during sleep or screen lock to prevent ghost touches and kernel panics.

Documentation:
- 🇺🇸 [English Documentation](README.md) (This file)
- 🇺🇦 [Українська документація](README.uk.md)

---

## Background

On MacBook Pro models with a Touch Bar:
- **Apple Silicon:** MacBook Pro (13", M1, 2020 — `MacBookPro17,1`), MacBook Pro (13", M2, 2022 — `Mac14,7`).
- **Intel (Touch Bar models):** MacBook Pro 13" (2016–2020 with 4 Thunderbolt ports; all 13" models from 2018 onwards) and MacBook Pro 15" (2016–2019). *(Models without a Touch Bar, such as the 13" 2016–2017 two-port variant, are unaffected).*

Over time, the Touch Bar OLED panel can die and stay completely black while the capacitive touch layer remains active, generating phantom touches. When combined with a worn or damaged lid-angle sensor (Hall effect sensor), closing the lid fails to put the laptop to sleep. As a result:
- Phantom touches wake the display while locked.
- Volume and brightness levels change erratically.
- The laptop stays warm and discharges the battery in a bag.

---

## Why Halting `TouchBarServer` Causes a Kernel Panic

A common suggestion found online is suspending Touch Bar processes via `kill -STOP`:

```bash
# Unsafe on newer macOS versions
kill -STOP $(pgrep TouchBarServer) $(pgrep ControlStrip)
```

In testing on a MacBook Pro (13", M1, 2020, `MacBookPro17,1`) running macOS 15+, suspending `TouchBarServer` eventually caused a Kernel Panic:

```text
panic(cpu 1 caller 0xfffffe001ec4cf3c): _dmaReferences overflow @IOMemoryDescriptor.cpp:5086
...
Kernel Extensions in backtrace:
   com.apple.driver.AppleMobileDispH13G-DFR
```

The `AppleMobileDispH13G-DFR` driver manages frame transmission to the Touch Bar via DMA. Halting `TouchBarServer` stops its message processing loop. The driver continues queueing frames, leading to an overflow of `_dmaReferences` inside `IOMemoryDescriptor` and triggering a kernel panic.

---

## How It Works

To prevent panics, `touchbar_guard` never sends signals to `TouchBarServer`. Instead, it manages only `ControlStrip`:

1. **Screen lock or sleep:** The daemon sends `SIGSTOP` to `ControlStrip`. Touch input on the bar no longer adjusts volume, brightness, or controls.
2. **DFR driver continues running:** `TouchBarServer` continues its event loop uninterrupted, allowing the display driver and DMA transactions to proceed normally.
3. **Screen unlock or wake:** The daemon sends `SIGCONT` to `ControlStrip`, restoring touch controls.

Events are detected via Darwin BSD notifications (`com.apple.sessionagent.*`, `com.apple.mobile.keybagd.lock_status`), IOKit power/display notifications (`IORegisterForSystemPower`, `IODisplayWrangler`), and Cocoa notifications (`NSWorkspace`, `NSDistributedNotificationCenter`).

---

## Limitations

- If `touchbar_guard` crashes or is killed (`kill -9`) while the screen is locked, `ControlStrip` will remain stopped. After unlocking, Touch Bar buttons will not respond to touches.
- To manually thaw `ControlStrip`, run:
  ```bash
  killall -CONT ControlStrip
  ```

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

Check daemon and `ControlStrip` status:

```bash
touchbar_guard --status
```

Flags:
```bash
touchbar_guard --status    # Show PID and state of daemon and ControlStrip
touchbar_guard --freeze    # Manually freeze ControlStrip (SIGSTOP)
touchbar_guard --thaw      # Manually thaw ControlStrip (SIGCONT)
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
