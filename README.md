# TouchBar Guard (`touchbar_guard`)

[![CI](https://github.com/g-autof/touchbar-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/g-autof/touchbar-guard/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/g-autof/touchbar-guard?color=blue)](https://github.com/g-autof/touchbar-guard/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-15%2B%20(tested)-blue.svg)](https://apple.com)
[![Architecture](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-orange.svg)](https://apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A lightweight macOS daemon that stops ghost touches and eliminates sleep-induced kernel panics on MacBook Pros with broken Touch Bars.

- 🇺🇸 [English](README.md)
- 🇺🇦 [Українська](README.uk.md)

---

## What It Fixes

On MacBook Pros where the Touch Bar display is dead (black) but the digitizer is still active:
- **Ghost Touches:** Phantom inputs wake the screen, blast volume, or trigger Siri while the laptop is locked or in a bag.
- **Kernel Panics (`_dmaReferences overflow`):** When the display sleeps, macOS enters an error loop that slowly leaks DMA references in the Touch Bar driver (`AppleMobileDispH13G-DFR`). After several hours of sleep, it overflows and crashes macOS.

---

## How It Works

1. **Freezes `ControlStrip` (`SIGSTOP`)** whenever the screen locks or sleeps. Phantom touches do nothing.
2. **Thaws `ControlStrip` (`SIGCONT`)** on unlock. Touch controls return immediately.
3. **Recycles `TouchBarServer` (`SIGKILL`)** on lock, wake, and every 30 minutes. `launchd` respawns it in <50ms with a clean queue, resetting leaked DMA references before they can trigger a panic.

---

## Installation

```bash
git clone https://github.com/g-autof/touchbar-guard.git
cd touchbar-guard
sudo ./install.sh
```

Or download the prebuilt binary from [Releases](https://github.com/g-autof/touchbar-guard/releases/latest).

---

## Usage

```bash
touchbar_guard --status     # View daemon, ControlStrip, and TouchBarServer state
touchbar_guard --freeze     # Manually freeze Touch Bar controls
touchbar_guard --thaw       # Manually thaw Touch Bar controls
touchbar_guard --recycle    # Manually reset TouchBarServer DMA queue (sudo)
```

View logs:
```bash
tail -f /var/log/touchbar_guard.log
```

---

## Uninstall

```bash
sudo ./uninstall.sh
```

---

## License

[MIT](LICENSE)
