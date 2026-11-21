#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly VERSION=stable-11509-1
readonly RELEASE_SHA=e1186a1818e47f9c30ce7c7eb637fa473d39c4c00d427d131da0b6c0fc71b3b1
readonly INSTALL_DIR=/opt/jitsi-meet
readonly NGINX_ROOT=/run/web/config
readonly PROSODY_CONFIG=/run/prosody/config/prosody.cfg.lua
readonly PROJECT=jitsi-meet

usage() {
    local installer=jitsi-install.sh
    local services='Jitsi Meet'
    if declare -F run_embedded_telemt >/dev/null; then
        installer=install.sh
        services='Jitsi Meet и Telemt WEB Proxy'
    fi

    cat <<HELP
Установка $services в Docker. Запускайте от root на сервере со свободными
TCP 80/443, UDP 10000 и локальными TCP 8080/8888. Нужны Docker Compose,
Python 3.11+, curl с HTTP/2 и публичный домен с одной IPv4-записью.

  sudo bash $installer --domain meet.example.com --email admin@example.com
  sudo bash $installer --domain meet.example.com --tls-cert fullchain.pem --tls-key privkey.pem

  --public-ip IPV4           Адрес медиамоста. По умолчанию берётся из DNS.
  --organizer NAME            Логин организатора. По умолчанию organizer.
  --with-telemt               После Jitsi настроить Telegram WEB Proxy.
  --telemt-base-path PATH     Путь WEB Proxy, по умолчанию jitsi/index.
                            Подразумевает --with-telemt.
  --telemt-installer FILE      Путь к установщику Telemt. Подразумевает --with-telemt.
  --check                     Проверка без развёртывания и записи файлов.
  --help                      Эта справка.

Для Let's Encrypt нужны доступ к CA и публичный вход на TCP 80.
Организатор входит по паролю, гости присоединяются после его входа.
Пароль хранится в /opt/jitsi-meet/organizer.env с правами 0600.
HELP

    if [[ $installer == install.sh ]]; then
        printf '%s\n' 'Telemt включён по умолчанию. Нужны Linux x86_64, Docker Compose 2.33.1+' \
            'и поддержка docker network connect --gw-priority.'
    else
        cat <<'HELP'
Обычный --with-telemt использует telemt-web-install.sh рядом с этим файлом.
Нужна версия установщика Telemt с поддержкой rootless Jitsi.
HELP
    fi
}

fail() {
    printf 'Ошибка: %s\n' "$*" >&2
    exit 1
}

while (( $# )); do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --check) check=1; shift ;;
        --with-telemt) with_telemt=1; shift ;;
        --domain|--public-ip|--email|--tls-cert|--tls-key|--organizer|--telemt-installer|--telemt-base-path)
            if (( $# < 2 )) || [[ $2 == --* ]]; then
                fail "Укажите значение для $1"
            fi
            case $1 in
                --domain) domain=$2 ;;
                --public-ip) public_ip=$2 ;;
                --email) email=$2 ;;
                --tls-cert) tls_cert=$2 ;;
                --tls-key) tls_key=$2 ;;
                --organizer) organizer=$2 ;;
                --telemt-installer) telemt_installer=$2; with_telemt=1 ;;
                --telemt-base-path) telemt_base_path=$2; with_telemt=1 ;;
            esac
            shift 2 ;;
        *) fail "Неизвестный аргумент $1. См. --help" ;;
    esac
done

[[ -n ${domain:-} ]] || fail 'Укажите --domain'
(( EUID == 0 )) || fail 'Запустите от root'
[[ $(uname -s) == Linux ]] || fail 'Для установки нужен Linux'

for command in docker python3 curl openssl sha256sum tar ss flock; do
    command -v "$command" >/dev/null || fail "Отсутствует команда $command"
done
docker info >/dev/null
docker compose version >/dev/null
curl_version=$(curl --version)
[[ $curl_version == *HTTP2* ]] || fail 'Нужен curl с поддержкой HTTP/2'

organizer=${organizer:-organizer}
[[ $organizer =~ ^[a-z][a-z0-9_]{0,31}$ ]] || fail 'Введите логин организатора латиницей в нижнем регистре'
email=${email:-}
tls_mode=manual
if [[ -n $email ]]; then
    [[ $email =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || fail 'Некорректный email'
    [[ -z ${tls_cert:-}${tls_key:-} ]] || fail 'Выберите --email либо пару --tls-cert и --tls-key'
    tls_mode=acme
else
    [[ -s ${tls_cert:-} && -s ${tls_key:-} ]] || fail 'Укажите --email либо читаемые --tls-cert и --tls-key'
    cert_pub=$(openssl x509 -in "$tls_cert" -noout -pubkey)
    key_pub=$(openssl pkey -in "$tls_key" -passin pass: -pubout)
    [[ $cert_pub == "$key_pub" ]] || fail 'Сертификат и ключ не совпадают'
    openssl x509 -in "$tls_cert" -noout -checkend 0 || fail 'Истёк срок действия сертификата'
    name_match=$(openssl x509 -in "$tls_cert" -noout -checkhost "$domain")
    [[ $name_match == *" does match certificate" ]] || fail 'Сертификат выпущен для другого домена'
fi

public_ip=$(python3 - "$domain" "${public_ip:-}" <<'PY'
import ipaddress
import re
import socket
import sys

if sys.version_info < (3, 11):
    sys.exit("Нужен Python 3.11 или новее.")
domain, expected = sys.argv[1:]
label = r"[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?"
if len(domain) > 253 or not re.fullmatch(rf"(?:{label}\.)+[a-z](?:[a-z0-9-]{{0,61}}[a-z0-9])?", domain):
    sys.exit("Домен должен быть полным DNS-именем в нижнем регистре.")
try:
    addresses = {item[4][0] for item in socket.getaddrinfo(domain, 443, socket.AF_INET, socket.SOCK_STREAM)}
except OSError as error:
    sys.exit(f"Ошибка DNS: {error}")
if len(addresses) != 1 or (expected and expected not in addresses):
    sys.exit("У домена должна быть одна IPv4-запись, совпадающая с --public-ip, если он задан.")
address = ipaddress.IPv4Address(addresses.pop())
if not address.is_global:
    sys.exit("Для Jitsi нужен публичный IPv4.")
print(address)
PY
)

if [[ ${with_telemt:-0} == 1 ]]; then
    [[ $(uname -m) == x86_64 ]] || fail 'Этот установщик Telemt поддерживает Linux x86_64'
    telemt_base_path=${telemt_base_path-jitsi/index}
    if (( ${#telemt_base_path} > 128 )) ||
        [[ ! $telemt_base_path =~ ^[A-Za-z0-9][A-Za-z0-9_-]*(/[A-Za-z0-9][A-Za-z0-9_-]*)*$ ]]; then
        fail 'Для --telemt-base-path нужен путь без начального и завершающего слеша'
    fi

    if [[ -n ${telemt_installer:-} ]] || ! declare -F run_embedded_telemt >/dev/null; then
        telemt_installer=${telemt_installer:-$(dirname "$(realpath -- "${BASH_SOURCE[0]}")")/telemt-web-install.sh}
        [[ -r $telemt_installer && -f $telemt_installer ]] || fail "Установщик Telemt не найден: $telemt_installer"
        grep -Fq '/run/web/config/nginx/nginx.conf' "$telemt_installer" ||
            fail 'Обновите telemt-web-install.sh до версии с поддержкой rootless Jitsi'
    fi

    docker compose version --short | python3 -c '
import re, sys
version = re.match(r"v?(\d+)\.(\d+)\.(\d+)", sys.stdin.read())
if not version or tuple(map(int, version.groups())) < (2, 33, 1):
    sys.exit("Для Telemt нужен Docker Compose 2.33.1 или новее.")
'
    connect_help=$(docker network connect --help)
    [[ $connect_help == *--gw-priority* ]] || fail 'Для Telemt Docker CLI должен поддерживать network connect --gw-priority'
fi

join_file=$INSTALL_DIR/organizer.env
marker=$INSTALL_DIR/.jitsi-installer
settings=$INSTALL_DIR/.env
override=$INSTALL_DIR/docker-compose.override.yml

render_marker() {
    printf '%s\n' "$VERSION" "$domain" "$public_ip" "$tls_mode" "$email" "$organizer"
}

compose() {
    local args=(--project-name "$PROJECT" --project-directory "$INSTALL_DIR"
        --env-file "$settings" -f "$INSTALL_DIR/docker-compose.yml")
    [[ ! -f $override ]] || args+=(-f "$override")
    docker compose "${args[@]}" "$@"
}

configure_telemt() {
    [[ ${with_telemt:-0} == 1 ]] || return 0
    local jitsi_web
    jitsi_web=$(compose ps -q web)
    [[ -n $jitsi_web ]] || fail 'Не найден запущенный веб-контейнер Jitsi для Telemt'

    local args=(--domain "$domain" --public-ip "$public_ip"
        --jitsi-container "$jitsi_web" --base-path "$telemt_base_path" "$@")
    if [[ -n ${telemt_installer:-} ]]; then
        bash "$telemt_installer" "${args[@]}"
    else
        run_embedded_telemt "${args[@]}"
    fi
}

verify_compose() {
    compose config --format json | python3 -c '
import json, sys
version, domain, ip, tls = sys.argv[1:]
services = json.load(sys.stdin)["services"]
expected = {
    "web": {"PUBLIC_URL": f"https://{domain}", "ENABLE_LETSENCRYPT": tls},
    "prosody": {"XMPP_DOMAIN": "meet.jitsi", "ENABLE_AUTH": "1", "ENABLE_GUESTS": "1", "AUTH_TYPE": "internal"},
    "jvb": {"JVB_ADVERTISE_IPS": ip},
    "jicofo": {"ENABLE_AUTH": "1", "AUTH_TYPE": "internal"},
}
ports = {"web": {(8000, "80", "tcp"), (8443, "443", "tcp")}, "jvb": {(10000, "10000", "udp")}}
for name in ("web", "prosody", "jvb", "jicofo"):
    service = services[name]
    if service["image"] != f"ghcr.io/jitsi/{name}:{version}":
        sys.exit(f"Неожиданный образ Compose для {name}.")
    for key, value in expected[name].items():
        if service["environment"].get(key) != value:
            sys.exit(f"Параметр {name}.{key} отличается от настроек установщика.")
    effective = {(p["target"], str(p["published"]), p["protocol"]) for p in service.get("ports", [])}
    if not ports.get(name, set()).issubset(effective):
        sys.exit(f"Отсутствует ожидаемый опубликованный порт для {name}.")
' "$VERSION" "$domain" "$public_ip" "$([[ $tls_mode == acme ]] && printf 1 || printf 0)"
}

https_ready() {
    local result
    result=$(curl --noproxy '*' -sS --http2 --max-time 5 -o /dev/null         -w '%{http_code} %{http_version}' "https://$domain/config.js" 2>/dev/null) || return 1
    [[ $result == '200 2' ]] || return 1

    # Проверяем, что Jicofo видит рабочий медиамост и сам медиамост отвечает.
    if ! compose exec -T jicofo curl -fsS --max-time 3 http://127.0.0.1:8888/stats 2>/dev/null |
        python3 -c 'import json,sys; sys.exit(json.load(sys.stdin)["bridge_selector"]["operational_bridge_count"] < 1)' 2>/dev/null; then
        return 1
    fi
    compose exec -T jvb curl -fsS --max-time 3 http://127.0.0.1:8080/about/health >/dev/null 2>&1
}

verify_nginx() {
    compose exec -T web nginx -t -c "$NGINX_ROOT/nginx/nginx.conf"
    compose exec -T web grep -Fq "include $NGINX_ROOT/nginx-custom/*.conf;" "$NGINX_ROOT/nginx/meet.conf"
}

organizer_exists() {
    compose exec -T prosody test -s "/var/lib/prosody/data/meet%2ejitsi/accounts/$organizer.dat"
}

if [[ ${check:-0} == 0 ]]; then
    exec 9>/run/lock/jitsi-install.lock
    flock -n 9 || fail 'Уже запущен другой экземпляр установщика Jitsi'
fi

installed=0
if [[ -e $INSTALL_DIR || -L $INSTALL_DIR ]]; then
    [[ ! -L $INSTALL_DIR && -f $marker && -f $settings && -f $join_file &&
        -f $INSTALL_DIR/docker-compose.yml ]] || fail "Каталог $INSTALL_DIR уже занят"
    cmp -s "$marker" <(render_marker) || fail "Параметры отличаются от предыдущего запуска в $INSTALL_DIR"
    if [[ $tls_mode == manual ]]; then
        if ! cmp -s "$tls_cert" "$INSTALL_DIR/config/web/keys/cert.crt" ||
            ! cmp -s "$tls_key" "$INSTALL_DIR/config/web/keys/cert.key"; then
            fail 'Сертификат или ключ отличается от установленного'
        fi
    fi
    verify_compose
    installed=1
else
    ports_in_use=$(ss -H -lntu | awk '
        ($1 == "tcp" && $5 ~ /:(80|443|8080|8888)$/) || ($1 == "udp" && $5 ~ /:10000$/) {print $1, $5}
    ')
    [[ -z $ports_in_use ]] || fail "Порты Jitsi уже заняты: $ports_in_use"
    other_project=$(docker ps -a --filter "label=com.docker.compose.project=$PROJECT" -q)
    [[ -z $other_project ]] || fail "Имя Compose-проекта $PROJECT уже используется"
fi

if [[ ${check:-0} == 1 ]]; then
    if (( installed )); then
        https_ready || fail 'Установленный Jitsi не прошёл проверку HTTPS или сервисов'
        verify_nginx
        organizer_exists || fail 'Не найден аккаунт организатора в Prosody'
        configure_telemt --check
        printf 'Jitsi и аккаунт организатора проверены. https://%s/\n' "$domain"
    else
        printf 'DNS, Docker и доступность локальных портов проверены. https://%s/\n' "$domain"
    fi
    exit 0
fi

if (( ! installed )); then
    staging=$(mktemp -d "$(dirname "$INSTALL_DIR")/.jitsi-install.XXXXXX")
    trap 'rm -rf -- "$staging"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    archive=$staging/release.tar.gz
    curl --noproxy '*' --fail --silent --show-error --location --retry 2 --max-time 90 \
        --proto '=https' --proto-redir '=https' \
        "https://codeload.github.com/jitsi/docker-jitsi-meet/tar.gz/refs/tags/$VERSION" -o "$archive"
    printf '%s  %s\n' "$RELEASE_SHA" "$archive" | sha256sum --check --status ||
        fail 'Контрольная сумма архива Jitsi не совпала'

    payload=$staging/project
    install -d -m 0700 "$payload"
    tar -xzf "$archive" -C "$payload" --strip-components=1 --no-same-owner --no-same-permissions \
        "docker-jitsi-meet-$VERSION/docker-compose.yml"
    render_marker >"$payload/.jitsi-installer"
    jicofo_secret=$(openssl rand -hex 32)
    jvb_secret=$(openssl rand -hex 32)
    organizer_secret=$(openssl rand -hex 24)

    cat >"$payload/.env" <<EOF
CONFIG=$INSTALL_DIR/config
PUBLIC_URL=https://$domain
HTTP_PORT=80
HTTPS_PORT=443
JVB_PORT=10000
JVB_ADVERTISE_IPS=$public_ip
TZ=UTC
JITSI_IMAGE_REPO=ghcr.io/jitsi
JITSI_IMAGE_VERSION=$VERSION
RESTART_POLICY=unless-stopped
ENABLE_HTTP_REDIRECT=1
ENABLE_JAAS_COMPONENTS=0
ENABLE_AUTH=1
ENABLE_GUESTS=1
AUTH_TYPE=internal
XMPP_DOMAIN=meet.jitsi
JICOFO_AUTH_PASSWORD=$jicofo_secret
JVB_AUTH_PASSWORD=$jvb_secret
EOF
    if [[ $tls_mode == acme ]]; then
        cat >>"$payload/.env" <<EOF
ENABLE_LETSENCRYPT=1
LETSENCRYPT_DOMAIN=$domain
LETSENCRYPT_EMAIL=$email
LETSENCRYPT_ACME_SERVER=letsencrypt
EOF
    else
        printf 'ENABLE_LETSENCRYPT=0\n' >>"$payload/.env"
    fi
    printf 'JITSI_ORGANIZER=%s\nJITSI_PASSWORD=%s\n' "$organizer" "$organizer_secret" >"$payload/organizer.env"

    # Каталоги для записи принадлежат uid/gid 1000 из rootless-образов Jitsi.
    install -d -m 0755 "$payload"/config/{web/nginx-custom,web/custom-ca,prosody/config,prosody/prosody-plugins-custom,prosody/custom-ca,jicofo/custom-ca,jvb/custom-ca}
    install -d -o 1000 -g 1000 -m 0750 "$payload"/config/{storage/web,storage/prosody,storage/transcripts,tmp/web-load-test}
    if [[ $tls_mode == manual ]]; then
        install -d -m 0755 "$payload/config/web/keys"
        install -m 0644 "$tls_cert" "$payload/config/web/keys/cert.crt"
        install -o 1000 -g 1000 -m 0600 "$tls_key" "$payload/config/web/keys/cert.key"
    fi

    mv -T -- "$payload" "$INSTALL_DIR"
    verify_compose
fi

compose up -d --no-recreate

deadline=$((SECONDS + 180))
until https_ready; do
    if (( SECONDS >= deadline )); then
        compose ps >&2
        fail "Jitsi не прошёл проверку HTTPS или сервисов. Конфигурация сохранена в $INSTALL_DIR для диагностики и повторного запуска"
    fi
    sleep 3
done
verify_nginx

if ! organizer_exists; then
    organizer_secret=$(sed -n 's/^JITSI_PASSWORD=//p' "$join_file")
    [[ $organizer_secret =~ ^[0-9a-f]{48}$ ]] || fail "Некорректный пароль в $join_file"
    # Пароль читается из stdin уже внутри Prosody.
    # shellcheck disable=SC2016
    printf '%s\n' "$organizer_secret" | compose exec -T prosody sh -c '
        set -eu
        IFS= read -r password
        prosodyctl --config "$1" register "$2" meet.jitsi "$password"
    ' sh "$PROSODY_CONFIG" "$organizer"
    organizer_exists || fail 'Prosody не сохранил аккаунт организатора'
fi

printf 'Jitsi готов: https://%s/\nЛогин и пароль организатора: %s\n' "$domain" "$join_file"
configure_telemt
