# TouchBar Guard (`touchbar_guard`)

[![macOS](https://img.shields.io/badge/platform-macOS%2012%2B-blue.svg)](https://apple.com)
[![Architecture](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-orange.svg)](https://apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Language](https://img.shields.io/badge/language-Objective--C-green.svg)](src/touchbar_guard.m)

Професійний, високоефективний системний демон для macOS, створений для нейтралізації **фантомних натискань** на моделях MacBook Pro зі зламаним, зношеним або чорним Touch Bar без виклику Kernel Panic.

Доступна документація:
- 🇺🇸 [English Documentation](README.md)
- 🇺🇦 [Українська документація](README.uk.md) (Цей файл)

---

## Апаратна проблема

На ноутбуках MacBook Pro з OLED-панеллю Touch Bar:
- **Apple Silicon:** MacBook Pro (13-дюймовий, M1, 2020 — `MacBookPro17,1`), MacBook Pro (13-дюймовий, M2, 2022 — `MacBookPro14,7`)
- **Intel:** MacBook Pro (13-дюймовий, 15-дюймовий, 16-дюймовий, 2016–2020)

З віком OLED-дисплей тачбара часто виходить з ладу: екран стає повністю чорним, проте ємнісний сенсорний шар (дигітайзер) залишається під напругою та починає реєструвати хаотичні **фантомні дотики** («примарні натискання»).

Коли ця несправність поєднується зі зношеним датчиком кута відкриття кришки (датчиком Холла), закриття кришки ноутбука не переводить Mac у режим сну. У результаті:
- Фантомні дотики постійно будять заблокований екран.
- Хаотично змінюється яскравість екрана та гучність динаміків.
- Мимовільно викликається Siri або вводяться випадкові натискання на екрані блокування.
- Ноутбук гріється в рюкзаку чи сумці та розряджає акумулятор у нуль.

---

## Фатальний баг популярних рішень: Kernel Panic

Популярні інструкції з форумів та Reddit зазвичай пропонують зупиняти тачбар командою `kill -STOP` для обох процесів:

```bash
# ⚠️ НЕБЕЗПЕЧНИЙ МЕТОД - ВИКЛИКАЄ KERNEL PANIC НА СУЧАСНИХ MACOS
kill -STOP $(pgrep TouchBarServer) $(pgrep ControlStrip)
```

На сучасних версіях macOS (macOS 14 Sonoma, macOS 15 Sequoia та новіших), заморожування процесу `TouchBarServer` гарантовано призводить до фатального краху ядра (**Kernel Panic**):

```text
panic(cpu 1 caller 0xfffffe001ec4cf3c): _dmaReferences overflow @IOMemoryDescriptor.cpp:5086
Debugger message: panic
Backtrace (CPU 1), panicked thread: 0xfffffe1ffc774640:
...
Kernel Extensions in backtrace:
   com.apple.driver.AppleMobileDispH13G-DFR
```

### Технічні причини збою ядра:
1. **Драйвер кадрового буфера DFR:** В архітектурах Apple Silicon та чипах T2 ядро використовує драйвери на кшталт `com.apple.driver.AppleMobileDispH13G-DFR` для обслуговування апаратного буфера Display Function Row (DFR).
2. **Клієнт сервера відображення:** Процес `TouchBarServer` є прямим клієнтом цього драйвера в просторі користувача.
3. **Зависання черги DMA:** Коли `TouchBarServer` отримує сигнал `SIGSTOP`, його цикл обробки повідомлень Mach зупиняється. Драйвер ядра продовжує генерувати транзакції DMA, проте зупинений клієнт більше не надсилає підтвердження завершення кадрів.
4. **Переповнення лічильника посилань:** На кожну транзакцію драйвер інкрементує лічильник посилань `_dmaReferences` в об'єкті ядра `IOMemoryDescriptor`. У ядрі XNU цей лічильник реалізований як знакове 16-бітне ціле число (максимальне значення: `32 767`).
5. **Аварійна зупинка (Panic):** Через короткий час `_dmaReferences` перевищує 32 767, спрацьовує перевірка переповнення в `IOMemoryDescriptor.cpp:5086`, і система миттєво перезавантажується.

---

## Хірургічне рішення

`touchbar_guard` використовує точний і протестований підхід:

> **Правило:** НІКОЛИ не надсилати сигнали процесу `TouchBarServer`! Заморожувати ТІЛЬКИ `ControlStrip`.

```text
┌────────────────────────────────────────────────────────┐
│             Подія блокування або сну екрана            │
└───────────────────────────┬────────────────────────────┘
                            │
              ┌─────────────▼─────────────┐
              │    Демон touchbar_guard   │
              └─────────────┬─────────────┘
                            │
              ┌─────────────▼─────────────┐
              │   SIGSTOP -> ControlStrip │
              └─────────────┬─────────────┘
                            │
       ┌────────────────────┴────────────────────┐
       ▼                                         ▼
┌──────────────────────────────┐   ┌──────────────────────────────┐
│  ControlStrip (Заморожено)   │   │ TouchBarServer (Активний)    │
│  - Немає реакції на дотики   │   │ - Кадрові транзакції в нормі │
│  - Гучність/яскравість мовчать│  │ - Черга DMA очищується       │
│  - Фантомні натискання знято │   │ - НУЛЬ витоків лічильників   │
└──────────────────────────────┘   └──────────────────────────────┘
```

1. **`ControlStrip` (`/System/Library/CoreServices/ControlStrip.app`)** — це виключно призначений для інтерфейсу користувача процес (AppKit/CoreGraphics), який відповідає за відображення кнопок, повзунків яскравості, гучності та кнопки Siri.
2. Призупинення `ControlStrip` сигналом `SIGSTOP` повністю вимикає обробку UI-подій тачбара. Фантомні дотики на дигітайзері не мають жодного ефекту.
3. Водночас `TouchBarServer` продовжує штатну взаємодію з драйвером `AppleMobileDispH13G-DFR`, виключаючи зупинку DMA-транзакцій або витік посилань дескриптора пам'яті.
4. При розблокуванні екрана або пробудженні дисплея демон надсилає `SIGCONT` процесу `ControlStrip`, миттєво повертаючи працездатність без жодних затримок.

---

## Багаторівневе перехоплення подій

Для надійного перехоплення всіх станів блокування, сну та перемикання користувачів `touchbar_guard` слухає події через чотири незалежні системи:

1. **Системні сповіщення Darwin BSD (`notify.h`):**
   - Блокування: `com.apple.sessionagent.screenIsLocked`, `com.apple.sessionagent.screenLockUIIsShown`, `com.apple.sessionagent.shieldWindowRaised`, `com.apple.mobile.keybagd.lock_status`, `com.apple.screensaver.didstart`.
   - Розблокування: `com.apple.sessionagent.screenIsUnlocked`, `com.apple.sessionagent.screenLockUIIsHidden`, `com.apple.sessionagent.shieldWindowLowered`, `com.apple.screensaver.didstop`.
2. **Розподілені сповіщення Cocoa (`NSDistributedNotificationCenter`):**
   - `com.apple.screenIsLocked`
   - `com.apple.screenIsUnlocked`
3. **Сповіщення підсистеми живлення та дисплея IOKit (`IOPMLib.h`, `IOMessage.h`):**
   - `IORegisterForSystemPower`: обробка `kIOMessageSystemWillSleep`, `kIOMessageSystemHasPoweredOn`, `kIOMessageCanSystemSleep`.
   - `IODisplayWrangler`: обробка вимкнення та увімкнення підсвічування екрана (`kIOMessageDeviceWillPowerOff`, `kIOMessageDeviceHasPoweredOn`).
4. **Сповіщення робочого простору AppKit (`NSWorkspace`):**
   - `NSWorkspaceScreensDidSleepNotification` та `NSWorkspaceScreensDidWakeNotification`
   - `NSWorkspaceWillSleepNotification` та `NSWorkspaceDidWakeNotification`
   - `NSWorkspaceSessionDidResignActiveNotification` та `NSWorkspaceSessionDidBecomeActiveNotification`

---

## Структура репозиторію

```text
touchbar-guard/
├── Makefile                                # Збірка, встановлення, видалення, перевірка статусу та логів
├── install.sh                              # Автоматизований скрипт встановлення з підвищенням прав
├── uninstall.sh                            # Скрипт чистого видалення з гарантованим розмороженням
├── LICENSE                                 # Ліцензія MIT
├── README.md                               # Документація англійською мовою
├── README.uk.md                            # Документація українською мовою
├── launchd/
│   ├── com.yustyna.touchbar_guard.plist    # Конфігурація сервісу launchd
│   └── com.github.touchbar_guard.plist     # Нейтральний маніфест для GitHub
└── src/
    └── touchbar_guard.m                    # Вихідний код демона на Objective-C
```

---

## Швидкий старт та встановлення

### Варіант 1: Через скрипт автоматичного встановлення (Рекомендовано)

```bash
git clone https://github.com/yustyna/touchbar-guard.git
cd touchbar-guard
sudo ./install.sh
```

### Варіант 2: За допомогою `make`

```bash
cd touchbar-guard
make universal
sudo make install
```

Скрипт інсталяції:
- Компілює універсальний бінарний файл Mach-O (`arm64` + `x86_64`).
- Встановлює його у `/usr/local/bin/touchbar_guard`.
- Налаштовує `/Library/LaunchDaemons/com.yustyna.touchbar_guard.plist` з прапорцями `RunAtLoad` та `KeepAlive`.
- Запускає службу через `launchctl bootstrap`.
- Створює лінійно-буферизований лог у `/var/log/touchbar_guard.log`.

---

## Перевірка статусу та діагностика

Перевірити статус демона та стан процесу `ControlStrip`:

```bash
touchbar_guard --status
```

Приклад виводу:
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

### Перегляд живих логів

```bash
make logs
# Або напряму:
tail -f /var/log/touchbar_guard.log
```

Приклад записів у лозі:
```text
[2026-11-16 23:15:02] [TouchBarGuard] BLOCKED Touch Bar [SIGSTOP -> ControlStrip (instances: 1)] (Reason: Screen lock UI shown)
[2026-11-16 23:15:18] [TouchBarGuard] UNBLOCKED Touch Bar [SIGCONT -> ControlStrip (instances: 1)] (Reason: Session screen unlocked)
```

---

## Видалення

Щоб повністю видалити демон, видалити службу з launchd та гарантовано розморозити `ControlStrip`:

```bash
sudo ./uninstall.sh
# Або через make:
sudo make uninstall
```

---

## Ліцензія

Цей проект поширюється на умовах ліцензії [MIT](LICENSE).
