# RobloxUnlocker

Набор скриптов для Windows, который возвращает загрузку ассетов Roblox: модели, текстуры, аватары, одежду, иконки и превью.

Решает две разные причины «серого» Roblox — и умеет доказать, какая из них у тебя.

```
service.bat  ->  1  (установить всё)
```

---

## Симптомы, которые это лечит

| Что видно в игре | Что не так |
|---|---|
| Модели и текстуры серые / не прогружаются | клиент висит на загрузке ассетов по QUIC |
| Аватары без одежды и аксессуаров | не скачиваются меши и текстуры одежды |
| Не грузятся иконки, превью, картинки в меню | мёртвые edge-адреса CDN в DNS |
| В игре всё «плывёт» первые секунды, потом тишина | часть CDN-адресов недоступна |
| Через VPN всё работает, без VPN — нет | проблема в сетевом пути, а не в аккаунте |

Если Roblox не запускается вообще или не подключается к серверам — это **не сюда**, тут про CDN и ассеты.

---

## Две причины и два лекарства

### 1. Провайдер режет QUIC (HTTP/3) — ассеты не качаются

Современный клиент Roblox качает ассеты по HTTP/3 поверх **UDP 443**. Некоторые провайдеры (в РФ — массово после блокировок) пропускают рукопожатие QUIC, а дальше молча дропают пакеты.

Клиент при этом **не откатывается на TCP**, а ждёт таймаут на каждый файл. В логе это выглядит так:

```
HttpResponse(#162 ...) time:60015.7ms (net:59999.4ms ...) error:5
message:HttpError: Timedout url:{ "https://fts.rbxcdn.com/v2/sc3/..." }
```

Проверено на пакетах: за 2 минуты клиент отправил **864 UDP-пакета** к CDN и получил **0** в ответ.

**Решение:** заблокировать исходящий UDP 443 для `RobloxPlayerBeta.exe`. Клиент обязан перейти на TCP/HTTP2, а TCP-путь обычно полностью здоров.

После фикса та же сессия: **22 МБ** ассетов по TCP, **0** таймаутов вместо 47–49.

### 2. Мёртвые edge-адреса CDN в DNS — картинки не грузятся

`tr.rbxcdn.com` и `fts.rbxcdn.com` раздаются через CloudFront/Akamai. Часть адресов из ответа DNS у конкретного провайдера — «чёрные дыры»: SYN уходит, ответа нет (проверяется за 3 секунды, см. диагностику). Клиент выбирает такой адрес и вешает на нём загрузку.

**Решение:** собрать адреса из нескольких независимых DoH-резолверов, проверить каждый (TCP + TLS), оставить в `hosts` только живые и быстрые.

---

## Установка

Требования: Windows 10/11, PowerShell 5.1 (встроен), права администратора для установки.

```bat
git clone https://github.com/StandarterDF/RobloxUnlocker.git
cd RobloxUnlocker
service.bat
```

Дальше — пункт **1**. Скрипт сам запросит UAC.

Полностью закрыть Roblox (все процессы `RobloxPlayerBeta`), запустить заново.

### Что именно делает пункт 1

1. Создаёт правила файрвола: **исходящий UDP 443 → Block** для каждого найденного `RobloxPlayerBeta.exe` и `RobloxStudioBeta.exe` (на все установленные версии).
2. Включает активный профиль файрвола, **не меняя политику по умолчанию** (входящие/исходящие разрешены, фильтруется только то, что мы добавили). Исходное состояние запоминается и восстанавливается при удалении.
3. Собирает и проверяет CDN-адреса, пишет управляемый блок в `hosts` (с резервной копией файла).
4. Ставит задачу планировщика `RobloxUnlocker-Refresh`: раз в 30 минут добавляет правило на новые версии Roblox, раз в 3 дня обновляет `hosts`.

---

## Меню

| Пункт | Что делает |
|---|---|
| 1 | Установить всё (QUIC + hosts + автоподдержка) |
| 2 | Статус: правила, hosts, задача, статистика последней сессии |
| 3 | Диагностика по логам Roblox + проверка адресов CDN |
| 4 | Захват QUIC через `pktmon` (90 с) — доказательство одностороннего потока |
| 5 | Пересобрать `hosts` (живые адреса CDN) |
| 6 | Убрать записи `hosts` |
| 7 / 8 | Включить / выключить автоподдержку |
| 9 | Полное удаление (все изменения отменяются) |

### Диагностика (пункт 3)

Показывает по последнему логу: сколько HTTP-запросов, сколько успешных, сколько зависаний `>= 50 c`, сколько ошибок ассетов, на каких хостах. Плюс проверяет доступность адресов `fts.rbxcdn.com` и `tr.rbxcdn.com`.

### Захват QUIC (пункт 4)

Снимает UDP 443 на 90 секунд через встроенный `pktmon` и печатает по каждому адресу: сколько отправлено и сколько получено. Если видно `отправлено 864 пакета / получено 0` — причина доказана, а не угадана.

---

## Ручные команды

```powershell
# только QUIC-фикс
powershell -ExecutionPolicy Bypass -File scripts\quic.ps1 -Mode block
powershell -ExecutionPolicy Bypass -File scripts\quic.ps1 -Mode unblock

# только hosts (с проверкой адресов)
powershell -ExecutionPolicy Bypass -File scripts\hosts.ps1 -Mode apply
powershell -ExecutionPolicy Bypass -File scripts\hosts.ps1 -Mode clean

# диагностика с захватом
powershell -ExecutionPolicy Bypass -File scripts\diagnose.ps1 -Capture -CaptureSeconds 120

# всё, кроме hosts
powershell -ExecutionPolicy Bypass -File scripts\install.ps1 -SkipHosts
```

Продвинутый сбор адресов (28 UDP-резолверов + DoH, только стандартная библиотека Python):

```bat
python tools\edge_collector.py --check
```

---

## Как это устроено

```
RobloxUnlocker/
├─ service.bat              меню
├─ scripts/
│  ├─ common.ps1            общие функции (сеть, hosts, логи, состояние)
│  ├─ install.ps1           установка
│  ├─ uninstall.ps1         полное удаление
│  ├─ quic.ps1              правила файрвола UDP 443
│  ├─ hosts.ps1             сбор/проверка адресов CDN и запись hosts
│  ├─ schedule.ps1          задача планировщика
│  ├─ refresh.ps1           фоновая поддержка актуальности
│  ├─ status.ps1            статус
│  └─ diagnose.ps1          диагностика (+ pktmon)
└─ tools/
   └─ edge_collector.py     расширенный сбор адресов
```

Служебные файлы: `%ProgramData%\RobloxUnlocker\`
(`state.json`, `unlocker.log`, резервные копии `hosts.backup.*`).

Управляемый блок в `hosts` ограничен маркерами:

```
# >>> RobloxUnlocker >>>
203.0.113.10 tr.rbxcdn.com
# <<< RobloxUnlocker <<<
```

---

## Удаление

`service.bat` → **9**. Удаляются правила файрвола, блок из `hosts` и задача планировщика; профиль файрвола возвращается в исходное состояние. Резервные копии `hosts` остаются в `%ProgramData%\RobloxUnlocker\`.

Точечно:

```powershell
Remove-NetFirewallRule -Group 'RobloxUnlocker'
Unregister-ScheduledTask -TaskName 'RobloxUnlocker-Refresh' -Confirm:$false
Set-NetFirewallProfile -Profile Private -Enabled False
```

---

## Частые вопросы

**Почему просто не отключить HTTP/3 флагом клиента?**
Fastflags в клиенте Roblox давно не читаются из `ClientAppSettings.json` (проверено: `DFIntHttp3FtsReqs=0` игнорируется, трафик остаётся QUIC). Флаги работают только в Studio.

**Почему именно файрвол?**
Это единственный способ запретить приложению QUIC, не трогая другие программы. На уровне роутера не выйдет: диапазоны CloudFront/Akamai огромные и меняются, а резать надо только UDP 443 конкретного процесса.

**Это безопасно?**
Правило блокирует только исходящий UDP 443 для процессов Roblox. Политики по умолчанию не меняются, при удалении всё возвращается. Резервная копия `hosts` создаётся перед каждой записью.

**Почему не VPN?**
VPN — рабочий обход, но он меняет маршрут всего трафика. Здесь лечится конкретная поломка, остальное работает напрямую.

**Roblox обновился, снова серые модели?**
Автоподдержка добавляет правило на новую версию в течение 30 минут. Если задача была выключена — `service.bat` → 1.

**Антивирус ругается на скрипты?**
Скрипты меняют файрвол и `hosts` — для эвристик это подозрительно. Код открыт, всё лежит в `scripts/`.

**Поможет ли это, если у меня блокируют IP Roblox целиком?**
Нет. Здесь лечится CDN и QUIC. Если `apis.roblox.com` и игровые серверы недоступны — нужен обход блокировок (zapret/GoodbyeDPI/VPN).

---

## Ограничения

- Только Windows (используются `netsh`/`NetSecurity`/`pktmon`).
- Нужны права администратора.
- Не чинит блокировку самих серверов Roblox и не заменяет VPN.
- `hosts`-часть зависит от текущей выдачи CDN: адреса со временем меняются, поэтому есть автообновление раз в 3 дня.
- Список адресов — не «магический», а проверенный: мёртвые отбрасываются по TCP+TLS.

---

## English (short)

PowerShell toolkit that fixes Roblox asset loading on Windows. It targets two independent causes:

1. **Broken QUIC (HTTP/3):** the ISP drops UDP 443 after the handshake, so Roblox waits 60 s per asset instead of falling back to TCP. Fix: block outbound UDP 443 for the Roblox executables.
2. **Dead CDN edges in DNS:** `fts/tr.rbxcdn.com` resolve to unreachable CloudFront/Akamai IPs. Fix: collect addresses from multiple DoH resolvers, verify each over TCP+TLS, pin the working ones in `hosts`.

Run `service.bat` → `1`. Requires Windows 10/11 and admin rights. `service.bat` → `4` captures real QUIC traffic with `pktmon` to prove the diagnosis. Uninstall is `service.bat` → `9`.

---

## Лицензия

MIT — см. [LICENSE](LICENSE).

Проект не связан с Roblox Corporation. Все изменения обратимы и выполняются только на локальной машине.
