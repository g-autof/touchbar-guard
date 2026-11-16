# TouchBar Guard (`touchbar_guard`)

[![macOS](https://img.shields.io/badge/macOS-15%2B%20(tested)-blue.svg)](https://apple.com)
[![Architecture](https://img.shields.io/badge/arch-arm64%20%7C%20x86__64-orange.svg)](https://apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Language](https://img.shields.io/badge/language-Objective--C-green.svg)](src/touchbar_guard.m)

Системний демон для macOS, що блокує реакцію Touch Bar під час сну або блокування екрана для запобігання фантомним натисканням та Kernel Panic.

Документація:
- 🇺🇸 [English Documentation](README.md)
- 🇺🇦 [Українська документація](README.uk.md) (Цей файл)

---

## Проблема

На ноутбуках MacBook Pro з панеллю Touch Bar:
- **Apple Silicon:** MacBook Pro (13", M1, 2020 — `MacBookPro17,1`), MacBook Pro (13", M2, 2022 — `Mac14,7`).
- **Intel (з Touch Bar):** MacBook Pro 13" з Touch Bar (2016–2020) та MacBook Pro 15" (2016–2019). *(Моделі 13" 2016–2017 з двома портами без Touch Bar цієї проблеми не мають).*

З часом дисплей Touch Bar може вийти з ладу (залишається чорним), проте сенсорна панель продовжує працювати і реєструвати випадкові натискання. Якщо при цьому зношений або пошкоджений датчик кута відкриття кришки (датчик Холла), закриття ноутбука не переводить систему в сон. У результаті:
- Сенсор будить заблокований екран.
- Мимовільно змінюються яскравість та гучність.
- Ноутбук гріється в сумці та розряджає батарею.

> **Примітка щодо сумісності:** Робота демона перевірена на MacBook Pro (13", M1, 2020) під macOS 15+. На старіших версіях macOS (12–14) та на комп'ютерах Intel тестування не проводилося. Підхід із зупинкою `ControlStrip` на Intel, найімовірніше, спрацює аналогічно, але драйвери кадрового буфера там інші, тому паніка через переповнення DMA спостерігалася саме на Apple Silicon.

---

## Чому не можна зупиняти `TouchBarServer` (Kernel Panic)

Популярна порада з мережі — зупиняти процеси Touch Bar через `kill -STOP`:

```bash
# Небезпечно на нових версіях macOS
kill -STOP $(pgrep TouchBarServer) $(pgrep ControlStrip)
```

У моїх тестах на MacBook Pro (13", M1, 2020, `MacBookPro17,1`) під керуванням macOS 15+ заморожування `TouchBarServer` через деякий час призводило до збою ядра (Kernel Panic):

```text
panic(cpu 1 caller 0xfffffe001ec4cf3c): _dmaReferences overflow @IOMemoryDescriptor.cpp:5086
...
Kernel Extensions in backtrace:
   com.apple.driver.AppleMobileDispH13G-DFR
```

Драйвер `AppleMobileDispH13G-DFR` відповідає за передачу кадрів на панель Touch Bar через DMA. Схоже, що коли процес `TouchBarServer` зупинено за допомогою `SIGSTOP`, черга кадрових повідомлень зависає, що, ймовірно, викликає переповнення лічильника `_dmaReferences` в об'єкті ядра `IOMemoryDescriptor` та аварійне перезавантаження системи.

---

## Принцип роботи

Щоб уникнути Kernel Panic, `touchbar_guard` не чіпає процес `TouchBarServer`, а керує виключно процесом `ControlStrip`:

1. **Блокування екрана або сон:** демон надсилає `SIGSTOP` процесу `ControlStrip`. Панель перестає реагувати на натискання (гучність, яскравість та кнопки UI не спрацьовують).
2. **Фонові драйвери:** `TouchBarServer` продовжує працювати у звичайному режимі, завдяки чому кадровий буфер та черга DMA опрацьовуються без помилок.
3. **Розблокування або пробудження:** демон надсилає `SIGCONT` процесу `ControlStrip`, повертаючи працездатність інтерфейсу.

Для відстеження подій демон підписується на системні сповіщення Darwin BSD (`com.apple.sessionagent.*`, `com.apple.mobile.keybagd.lock_status`), події підсистеми живлення та підсвічування IOKit (`IORegisterForSystemPower`, `IODisplayWrangler`), а також повідомлення `NSWorkspace` та `NSDistributedNotificationCenter`.

---

## Обмеження

- Демон коректно обробляє сигнали виходу (`SIGTERM`, `SIGINT`, `SIGQUIT`) і автоматично надсилає `SIGCONT` процесу `ControlStrip` перед завершенням роботи. Також перевірка та розморожування виконуються при старті демона, якщо екран не заблоковано.
- `ControlStrip` може залишитися замороженим лише в разі аварійного падіння демона або примусового завершення через `kill -9` (`SIGKILL`) у момент, коли екран був заблокований.
- Якщо це сталося, розморозити `ControlStrip` вручну можна командою:
  ```bash
  killall -CONT ControlStrip
  ```

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

Перевірити статус демона та стан `ControlStrip`:

```bash
touchbar_guard --status
```

Корисні прапорці:
```bash
touchbar_guard --status    # Показати PID і стан touchbar_guard та ControlStrip
touchbar_guard --freeze    # Вручну заморозити ControlStrip (SIGSTOP)
touchbar_guard --thaw      # Вручну розморозити ControlStrip (SIGCONT)
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
