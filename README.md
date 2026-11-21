# jitsi-telemt-installers

Установщики для Linux разворачивают Jitsi Meet в Docker и добавляют к нему Telemt WEB Proxy для Telegram. Прокси использует домен и HTTPS-порт Jitsi. По умолчанию Nginx направляет запросы с пути `/jitsi/index/` в отдельный контейнер Telemt.

| Установщик | Что устанавливает | Документация |
| --- | --- | --- |
| [`install.sh`](install.sh) | Jitsi Meet и Telemt WEB Proxy на новом сервере | [Совместная установка](#новый-сервер-с-jitsi-meet-и-telemt) |
| [`jitsi-install.sh`](jitsi-install.sh) | Jitsi Meet `stable-11509-1` с HTTPS и аккаунтом организатора | [Установка и диагностика Jitsi](README-jitsi.md) |
| [`telemt-web-install.sh`](telemt-web-install.sh) | Telemt `3.5.17` для работающего Jitsi Meet в Docker | [Установка и диагностика Telemt](README-telemt-web.md) |

## Перед запуском

- Нужны Linux, права root, работающий Docker с плагином Docker Compose, Bash, Python 3.11+ и `curl` с поддержкой HTTP/2.
- Домен должен разрешаться в один публичный IPv4. Для новой установки Jitsi нужны свободные TCP-порты 80, 443, 8080 и 8888, а также UDP-порт 10000. Откройте входящие TCP 443 и UDP 10000. Для Let's Encrypt также нужен публичный доступ по TCP 80.
- Для Telemt дополнительно нужны Linux x86_64, Docker Compose 2.33.1+ и поддержка `docker network connect --gw-priority`.

## Быстрый старт

Выполняйте команды на сервере из каталога со скриптами. Замените `meet.example.com` и `admin@example.com` своими значениями. В примерах Jitsi получает сертификат через Let's Encrypt. Подключение собственного сертификата описано в руководстве по Jitsi.

### Новый сервер с Jitsi Meet и Telemt

Скопируйте на сервер `install.sh`. Он сначала разворачивает Jitsi, затем настраивает Telemt на том же домене.

```bash
sudo bash install.sh --domain meet.example.com --email admin@example.com --check
sudo bash install.sh --domain meet.example.com --email admin@example.com
```

Jitsi будет доступен по адресу `https://meet.example.com/`. Логин и пароль организатора сохраняются в `/opt/jitsi-meet/organizer.env`. Путь WEB Proxy по умолчанию — `/jitsi/index/`. Его можно изменить параметром `--telemt-base-path`.

На новом сервере `--check` проверяет предпосылки для развёртывания. После установки этот же вызов проверяет работающие сервисы. Если установка остановилась на этапе Telemt, повторите команду установки с теми же параметрами.

### Новый сервер только с Jitsi Meet

```bash
sudo bash jitsi-install.sh --domain meet.example.com --email admin@example.com --check
sudo bash jitsi-install.sh --domain meet.example.com --email admin@example.com
```

### Telemt для уже работающего Jitsi Meet

```bash
sudo bash telemt-web-install.sh --domain meet.example.com --check
sudo bash telemt-web-install.sh --domain meet.example.com
```

После установки Telemt любым из способов откройте ссылку из `/root/telemt-web/web-proxy-link.txt` в клиенте Telegram с поддержкой прокси типа WEB. Ссылка содержит секрет доступа.

Полный список параметров доступен через `bash install.sh --help`, `bash jitsi-install.sh --help` и `bash telemt-web-install.sh --help`.

## Сборка общего установщика

После изменения исходных установщиков пересоберите `install.sh`.

```bash
bash build-installer.sh > install.sh
```
