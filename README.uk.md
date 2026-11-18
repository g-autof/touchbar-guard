# TouchBar Guard (`touchbar_guard`)

[![CI](https://github.com/g-autof/touchbar-guard/actions/workflows/ci.yml/badge.svg)](https://github.com/g-autof/touchbar-guard/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/g-autof/touchbar-guard?color=blue)](https://github.com/g-autof/touchbar-guard/releases/latest)
[![macOS](https://img.shields.io/badge/macOS-15%2B%20(tested)-blue.svg)](https://apple.com)
[![Architecture](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-orange.svg)](https://apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Language](https://img.shields.io/badge/language-Objective--C-green.svg)](src/touchbar_guard.m)

Системний демон для macOS, що блокує фантомні натискання Touch Bar на пошкоджених ноутбуках та усуває Kernel Panic через переповнення `_dmaReferences`.

Документація:
- 🇺🇸 [English Documentation](README.md)
- 🇺🇦 [Українська документація](README.uk.md) (Цей файл)

---

## Проблема

На ноутбуках MacBook Pro з панеллю Touch Bar:
- **Apple Silicon:** MacBook Pro (13", M1, 2020 — `MacBookPro17,1`), MacBook Pro (13", M2, 2022 — `Mac14,7`).
- **Intel (з Touch Bar):** MacBook Pro 13" з Touch Bar (2016–2020) та MacBook Pro 15" (2016–2019). *(Моделі 13" 2016–2017 з двома портами без Touch Bar цієї проблеми не мають).*

З часом часто виникає поєднання двох несправностей:
1. Дисплей Touch Bar виходить з ладу (залишається повністю чорним), проте сенсорний шар продовжує працювати і хаотично генерує фантомні натискання.
2. Зношується або ламається датчик кута відкриття кришки (датчик Холла), через що ноутбук не переходить у режим сну при закритті.

Це спричиняє дві критичні проблеми:
- **Фантомний ввід:** Дотики самовільно вмикають заблокований екран, викручують гучність чи яскравість на максимум або запускають Siri, поки комп'ютер у рюкзаку.
- **Kernel Panic (`_dmaReferences overflow`):** Коли екран гасне або блокується, `TouchBarServer` входить у цикл помилки за відсутності робочого вікна (`SLSHMDGetDrawable - unexpected server error response: 1000`) із частотою ~70 Гц. У драйвері `AppleMobileDispH13G-DFR` непідтверджені операції DMA спричиняють витік посилань у лічильнику `_dmaReferences` об'єкта `IOMemoryDescriptor` ядра XNU. Оскільки цей лічильник є знаковим 16-бітним числом (`OSAddAtomic16`), після досягнення 32 767 операцій (~8–16 годин простою) стається переповнення і ядро падає в паніку:
  ```text
  panic(cpu 1 caller 0xfffffe00489a1ee4): _dmaReferences overflow @IOMemoryDescriptor.cpp:5086
  Kernel Extensions in backtrace:
     com.apple.driver.AppleMobileDispH13G-DFR
  ```

> **Примітка щодо сумісності:** Робота демона перевірена на MacBook Pro (13", M1, 2020) під macOS 15+. На старіших версіях macOS (12–14) та на комп'ютерах Intel тестування не проводилося. Підхід із зупинкою `ControlStrip` на Intel, найімовірніше, спрацює аналогічно, але драйвери кадрового буфера там інші, тому паніка через переповнення DMA спостерігалася саме на Apple Silicon.

---

## Принцип роботи

`touchbar_guard` реалізує двошаровий захист:

### 1. Захист від фантомних натискань (`ControlStrip`)
- **Блокування екрана або сон:** демон надсилає `SIGSTOP` процесу `ControlStrip`. Сенсорна панель більше не змінює гучність, яскравість і не смикає елементи керування.
- **Розблокування або пробудження:** демон надсилає `SIGCONT` процесу `ControlStrip`, миттєво повертаючи керування.

### 2. DMA Watchdog (`TouchBarServer`)
- Заморожувати `TouchBarServer` через `SIGSTOP` категорично не можна: це блокує цикл черги DMA і викликає Kernel Panic уже за кілька хвилин.
- Проте примусовий перезапуск `TouchBarServer` через `SIGKILL` є абсолютно безпечним: `launchd` миттєво (< 50 мс) піднімає новий процес із чистим сеансом SkyLight та скинутою чергою DMA.
- `touchbar_guard` виступає сторожовим таймером (watchdog): він робить рецикл `TouchBarServer` під час блокування, розблокування та кожні 30 хвилин у фоні. Це щоразу скидає накопичені посилання DMA в нуль і назавжди запобігає досягненню ліміту 32 767.

Події відстежуються через сповіщення Darwin BSD (`com.apple.sessionagent.*`, `com.apple.mobile.keybagd.lock_status`), IOKit (`IORegisterForSystemPower`, `IODisplayWrangler`), Cocoa (`NSWorkspace`, `NSDistributedNotificationCenter`) та GCD dispatch timer.

---

## Обмеження

- Демон коректно обробляє сигнали виходу (`SIGTERM`, `SIGINT`, `SIGQUIT`) і автоматично надсилає `SIGCONT` процесу `ControlStrip` перед завершенням роботи. Також перевірка та розморожування виконуються при старті демона, якщо екран не заблоковано.
- `ControlStrip` може залишитися замороженим лише в разі аварійного падіння демона або примусового завершення через `kill -9` (`SIGKILL`) у момент, коли екран був заблокований.
- Якщо це сталося, розморозити `ControlStrip` вручну можна командою:
  ```bash
  killall -CONT ControlStrip
  ```
- Для рециклу `TouchBarServer` потрібні права root (демон під `launchd` виконується як root автоматично). Ручний виклик `--recycle` вимагає `sudo`.

---

## Структура репозиторію

```text
touchbar-guard/
├── Makefile                                # Збірка, встановлення, видалення, статус
├── install.sh                              # Скрипт встановлення
├── uninstall.sh                            # Скрипт видалення
├── LICENSE                                 # Ліцензія MIT
├── README.md                               # Англійська документація
├── README.uk.md                            # Українська документація
├── launchd/
│   └── com.github.touchbar_guard.plist     # Конфігурація для launchd
└── src/
    └── touchbar_guard.m                    # Вихідний код на Objective-C
```

---

## Встановлення

### Варіант 1: Скрипт інсталяції

```bash
git clone https://github.com/g-autof/touchbar-guard.git
cd touchbar-guard
sudo ./install.sh
```

### Варіант 2: Через `make`

```bash
cd touchbar-guard
make universal
sudo make install
```

Скрипт збирає універсальний бінарник (`arm64` + `x86_64`), копіює його в `/usr/local/bin/touchbar_guard`, реєструє службу `/Library/LaunchDaemons/com.github.touchbar_guard.plist` та запускає її через `launchd`. Логи пишуться у `/var/log/touchbar_guard.log`.

---

## Перевірка статусу та команди

Перевірити статус демона, `ControlStrip` та `TouchBarServer`:

```bash
touchbar_guard --status
```

Корисні прапорці:
```bash
touchbar_guard --status    # Показати PID і стан touchbar_guard, ControlStrip та TouchBarServer
touchbar_guard --freeze    # Вручну заморозити ControlStrip (SIGSTOP)
touchbar_guard --thaw      # Вручну розморозити ControlStrip (SIGCONT)
touchbar_guard --recycle   # Вручну перезапустити TouchBarServer (SIGKILL, потрібен sudo)
touchbar_guard -f          # Запуск демона у foreground (для налагодження)
```

Ціль `make test` компілює бінарник та перевіряє прапорці `--help`, `--version`, `--status`, коректність обробки невідомих параметрів, а також виконує пробний цикл freeze/thaw.

### Логи

```bash
tail -f /var/log/touchbar_guard.log
# або
make logs
```

---

## Видалення

Зупинити службу, видалити файли та розморозити `ControlStrip`:

```bash
sudo ./uninstall.sh
# або
sudo make uninstall
```

---

## Ліцензія

[MIT](LICENSE)
