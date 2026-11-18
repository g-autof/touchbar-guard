# TouchBar Guard (`touchbar_guard`)

[![CI](https://github.com/g-autof/touchbar-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/g-autof/touchbar-guard/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/g-autof/touchbar-guard?color=blue)](https://github.com/g-autof/touchbar-guard/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-15%2B%20(tested)-blue.svg)](https://apple.com)
[![Architecture](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-orange.svg)](https://apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Легкий системний демон для macOS, який блокує фантомні натискання та усуває Kernel Panic під час сну на MacBook Pro з пошкодженим Touch Bar.

- 🇺🇸 [English](README.md)
- 🇺🇦 [Українська](README.uk.md)

---

## Що це вирішує

На моделях, де екран Touch Bar згорів (чорний), але сенсорний шар досі живий:
- **Фантомні натискання:** Сенсор будить заблокований екран, викручує гучність/яскравість або запускає Siri, поки макбук лежить у рюкзаку.
- **Kernel Panic (`_dmaReferences overflow`):** Коли екран гасне, система потрапляє у цикл помилок драйвера Touch Bar (`AppleMobileDispH13G-DFR`). За кілька годин простою накопичується витік DMA-посилань, що переповнює лічильник ядра та валить macOS у паніку.

---

## Як це працює

1. **Заморожує `ControlStrip` (`SIGSTOP`)** при блокуванні або сні екрана. Фантомні дотики ігноруються.
2. **Розморожує `ControlStrip` (`SIGCONT`)** при розблокуванні. Керування повертається миттєво.
3. **Перезапускає `TouchBarServer` (`SIGKILL`)** при блокуванні, пробудженні та кожні 30 хвилин. `launchd` миттєво (<50 мс) піднімає чистий процес, скидаючи лічильник DMA в нуль і не даючи системі впасти в паніку.

---

## Встановлення

```bash
git clone https://github.com/g-autof/touchbar-guard.git
cd touchbar-guard
sudo ./install.sh
```

Або завантаж готовий бінарник із розділу [Releases](https://github.com/g-autof/touchbar-guard/releases/latest).

---

## Керування

```bash
touchbar_guard --status     # Перевірити статус демона і процесів Touch Bar
touchbar_guard --freeze     # Вручну заморозити кнопки Touch Bar
touchbar_guard --thaw       # Вручну розморозити кнопки Touch Bar
touchbar_guard --recycle    # Вручну скинути чергу DMA TouchBarServer (sudo)
```

Перегляд логів:
```bash
tail -f /var/log/touchbar_guard.log
```

---

## Видалення

```bash
sudo ./uninstall.sh
```

---

## Ліцензія

[MIT](LICENSE)
