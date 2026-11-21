#!/usr/bin/env bash
# Рендереры вызываются по имени, cleanup вызывается через trap.
# shellcheck disable=SC2317
set -Eeuo pipefail
umask 077

readonly VERSION=3.5.17
readonly ASSET=telemt-x86_64-linux-musl.tar.gz
readonly ARCHIVE_SHA=f1591635849e0aad31f147692b21726da2f49499aae3ece79f8760c92925133a
readonly BINARY_SHA=b73bc1275da2e7f136a7c8df2da6e9692d1feefdaa649f2622cd207d742f6f60
readonly INSTALL_DIR=/root/telemt-web
readonly NETWORK=telemt-web-ingress
readonly CONTAINER=telemt-web
readonly CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

usage() {
    cat <<'HELP'
Установка Telemt WEB Proxy рядом с работающим Jitsi Meet в Docker.

  sudo bash telemt-web-install.sh --domain DOMAIN [--public-ip IPV4]
      [--base-path jitsi/index] [--jitsi-container NAME]
      [--subnet 172.30.85.0/29] [--check]

Нужны Linux x86_64, Docker Compose v2.33.1+, Python 3.11+, curl, openssl
и работающий HTTPS Jitsi на указанном домене. Без --public-ip используется
единственная IPv4-запись домена. --check выполняет проверки без изменений.

Устанавливает отдельный контейнер Telemt с приватным слушателем, добавляет
маршрут в Nginx Jitsi и сохраняет ссылку в /root/telemt-web/web-proxy-link.txt.
Повторный запуск использует прежний секрет. Если найден несовместимый
конфигурационный файл, установка останавливается с указанием его пути.
HELP
}

fail() {
    printf 'Ошибка: %s\n' "$*" >&2
    exit 1
}

while (( $# )); do
    case $1 in
        -h|--help) usage; exit 0 ;;
        --check) check=1; shift ;;
        --domain|--public-ip|--base-path|--jitsi-container|--subnet)
            if (( $# < 2 )) || [[ $2 == --* ]]; then
                fail "Укажите значение для $1"
            fi
            case $1 in
                --domain) domain=$2 ;;
                --public-ip) public_ip=$2 ;;
                --base-path) base=$2 ;;
                --jitsi-container) jitsi=$2 ;;
                --subnet) subnet=$2 ;;
            esac
            shift 2
            ;;
        *) fail "Неизвестный аргумент $1. См. --help" ;;
    esac
done

[[ -n ${domain:-} ]] || fail 'Укажите --domain'
(( EUID == 0 )) || fail 'Запустите от root'
[[ $(uname -s) == Linux && $(uname -m) == x86_64 ]] || fail 'Поддерживается Linux x86_64'
base=${base:-jitsi/index}
subnet=${subnet:-172.30.85.0/29}

for command in docker python3 curl openssl sha256sum flock tar; do
    command -v "$command" >/dev/null || fail "Отсутствует команда $command"
done
[[ -s $CA_BUNDLE ]] || fail "Отсутствует $CA_BUNDLE"

docker info >/dev/null
docker compose version --short | python3 -c '
import re, sys
m = re.match(r"v?(\d+)\.(\d+)\.(\d+)", sys.stdin.read())
if not m or tuple(map(int, m.groups())) < (2, 33, 1):
    sys.exit("Нужна версия Docker Compose 2.33.1 или новее.")
'
connect_help=$(docker network connect --help)
[[ $connect_help == *--gw-priority* ]] || fail 'Docker CLI должен поддерживать network connect --gw-priority'

addresses=$(python3 - "$domain" "${public_ip:-}" "$base" "$subnet" <<'PY'
import ipaddress
import re
import socket
import sys
if sys.version_info < (3, 11):
    sys.exit("Нужен Python 3.11 или новее.")

domain, public_ip, base, subnet = sys.argv[1:]
domain_re = r"(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?"
if len(domain) > 253 or not re.fullmatch(domain_re, domain):
    sys.exit("Домен должен быть полным DNS-именем в нижнем регистре.")
if len(base) > 128 or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*(?:/[A-Za-z0-9][A-Za-z0-9_-]*)*", base):
    sys.exit("Некорректный --base-path. Укажите путь без ведущего и завершающего /.")
if base.split("/", 1)[0] in {"http-bind", "xmpp-websocket", "libs", "css", "static", "images", "fonts", "lang", "sounds", "transcripts"}:
    sys.exit("Выбранный путь пересекается со служебным маршрутом Jitsi.")
try:
    answers = {row[4][0] for row in socket.getaddrinfo(domain, 443, socket.AF_INET, socket.SOCK_STREAM)}
    if len(answers) != 1 or (public_ip and public_ip not in answers):
        sys.exit("Домен должен указывать на один IPv4, совпадающий с --public-ip, если он задан.")
    public = ipaddress.IPv4Address(answers.pop())
    net = ipaddress.IPv4Network(subnet)
except (ValueError, OSError) as error:
    sys.exit(f"Ошибка DNS или IP: {error}")
private = ("10.0.0.0/8", "172.16.0.0/12", "192.168.0.0/16")
if not public.is_global or net.prefixlen != 29 or not any(net.subnet_of(ipaddress.IPv4Network(p)) for p in private):
    sys.exit("Нужны публичный IPv4 и приватная подсеть /29.")
print(public, net[2], net[3])
PY
)
read -r public_ip nginx_ip telemt_ip <<<"$addresses"

if [[ -z ${jitsi:-} ]]; then
    candidates=$(docker ps --filter label=com.docker.compose.service=web --format '{{.Names}} {{.Image}}')
    mapfile -t matches < <(awk '$2 ~ /(^|\/)jitsi\/web[:@]/ { print $1 }' <<<"$candidates")
    (( ${#matches[@]} == 1 )) || fail 'Укажите --jitsi-container с именем контейнера Jitsi web'
    jitsi=${matches[0]}
fi

docker inspect -f '{{.State.Running}} {{index .Config.Labels "com.docker.compose.service"}}' "$jitsi" |
    grep -qx 'true web' || fail "$jitsi должен быть запущенным Compose-сервисом web"
project=$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$jitsi")
cfg=$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/config"}}{{.Source}}{{end}}{{end}}' "$jitsi")
[[ -d $project && -d $cfg ]] || fail 'Не найдены каталог Compose Jitsi и bind mount /config'
[[ -f $project/docker-compose.yml && ! -e $project/compose.yaml && ! -e $project/compose.yml &&
    ! -e $project/docker-compose.yaml && ! -e $project/docker-compose.override.yaml ]] ||
    fail "В $project нужен основной файл docker-compose.yml"
override=$project/docker-compose.override.yml
route=$cfg/nginx-custom/telemt-web.conf
proxy_config=$INSTALL_DIR/telemt.toml
link_file=$INSTALL_DIR/web-proxy-link.txt

# В rootless-образах Jitsi Nginx читает копию конфигурации из /run.
nginx_root=/config
if docker exec "$jitsi" test -f /run/web/config/nginx/nginx.conf; then
    nginx_root=/run/web/config
fi
nginx_config=$nginx_root/nginx/nginx.conf
runtime_route=$nginx_root/nginx-custom/telemt-web.conf

render_override() {
    cat <<EOF
services:
  web:
    networks:
      telemt-web-ingress:
        ipv4_address: $nginx_ip
        gw_priority: -1

networks:
  telemt-web-ingress:
    external: true
    name: telemt-web-ingress
EOF
}

render_nginx() {
    cat <<EOF
location = /$base {
    access_log off;
    return 404;
}

location ^~ /$base/ {
    access_log off;
    error_log /dev/null;
    client_max_body_size 2m;
    client_body_timeout 65s;
    send_timeout 65s;

    if (\$scheme = http) {
        return 404;
    }

    proxy_pass http://$telemt_ip:18080;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header X-Forwarded-For \$remote_addr;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection \$connection_upgrade;

    proxy_connect_timeout 5s;
    proxy_send_timeout 65s;
    proxy_read_timeout 65s;
    proxy_request_buffering off;
    proxy_buffering off;
    proxy_next_upstream off;
}
EOF
}

render_telemt() {
    cat <<EOF
[general]
use_middle_proxy = false

[general.links]
show = ["web-user"]

[server.api]
enabled = false

[access.users]
web-user = "$secret"

[[server.listeners]]
ip = "$telemt_ip"
port = 18080
transport = "web"
proxy_protocol = false
web_client_ip_source = "x_forwarded_for"
web_trusted_proxy_cidrs = ["$nginx_ip/32"]

[web]
enabled = true
carrier = "https"

[[web.vhosts]]
host = "$domain"
base_path = "$base"
public_addr = "$public_ip:443"

[web.vhosts.decoy]
mode = "static_directory"
directory = "/public"
index = "index.html"

[[web.vhosts.profiles]]
user = "web-user"
secret_mode = "dd"
max_sessions = 8
max_streams = 64
max_streams_per_session = 16
EOF
}

render_compose() {
    cat <<EOF
services:
  web:
    image: local/telemt-web:$VERSION
    build: .
    container_name: $CONTAINER
    command: ["/telemt.toml"]
    restart: unless-stopped
    cap_drop: [ALL]
    security_opt: [no-new-privileges:true]
    read_only: true
    tmpfs:
      - /state:size=16m
    volumes:
      - ./telemt.toml:/telemt.toml:ro
      - ./public:/public:ro
      - $CA_BUNDLE:$CA_BUNDLE:ro
    networks:
      ingress:
        ipv4_address: $telemt_ip
    logging:
      driver: local
      options:
        max-size: 2m
        max-file: "2"

networks:
  ingress:
    external: true
    name: $NETWORK
EOF
}

render_dockerfile() {
    cat <<'EOF'
FROM scratch
COPY telemt /telemt
WORKDIR /state
ENTRYPOINT ["/telemt"]
EOF
}

render_dockerignore() {
    printf '*\n!telemt\n!Dockerfile\n'
}

render_decoy() {
    cat <<'EOF'
<!doctype html>
<html lang="en"><meta charset="utf-8"><title>Jitsi Meet</title>
<h1>Jitsi Meet</h1><p><a href="/">Open Jitsi Meet</a></p></html>
EOF
}

matches_if_present() {
    local file=$1 renderer=$2
    [[ ! -L $file ]] || fail "$file является символической ссылкой"
    if [[ -e $file ]]; then
        if [[ ! -f $file ]] || ! cmp -s "$file" <("$renderer"); then
            fail "Найден несовместимый файл $file"
        fi
    fi
}

read_secret() {
    python3 - "$proxy_config" <<'PY'
import re
import sys
import tomllib

with open(sys.argv[1], "rb") as config:
    secret = tomllib.load(config)["access"]["users"]["web-user"]
if not re.fullmatch(r"[0-9a-f]{32}", secret):
    sys.exit("Некорректный секрет web-user в существующем telemt.toml.")
print(secret)
PY
}

jitsi_compose() {
    # Явные файлы исключают влияние COMPOSE_FILE из вызывающего окружения.
    local args=(--project-directory "$project" -f "$project/docker-compose.yml")
    [[ ! -f $override ]] || args+=(-f "$override")
    docker compose "${args[@]}" "$@"
}

telemt_compose() {
    docker compose --project-directory "$INSTALL_DIR" -p telemt-web -f "$INSTALL_DIR/compose.yaml" "$@"
}

network_ip() {
    docker inspect -f '{{with index .NetworkSettings.Networks "telemt-web-ingress"}}{{.IPAddress}}{{end}}' "$1"
}

verify() {
    python3 - "$domain" "$base" "$proxy_config" "$link_file" "$1" <<'PY'
import base64
import hmac
import os
import pathlib
import re
import sys
import tempfile
import tomllib
import urllib.error
import urllib.parse
import urllib.request

domain, prefix, config_path, link_path, mode = sys.argv[1:]
with open(config_path, "rb") as config:
    client_secret = b"\xdd" + bytes.fromhex(tomllib.load(config)["access"]["users"]["web-user"])

def encode(value):
    return base64.urlsafe_b64encode(value).rstrip(b"=").decode("ascii")

class NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args, **kwargs):
        return None

opener = urllib.request.build_opener(urllib.request.ProxyHandler({}), NoRedirect())
root = f"https://{domain}"
base = f"{root}/{prefix}/"

def request(url, expected, method="GET", data=None, headers=None):
    req = urllib.request.Request(url, data=data, headers=headers or {}, method=method)
    try:
        with opener.open(req, timeout=8) as response:
            status, headers, body = response.status, response.headers, response.read()
    except urllib.error.HTTPError as error:
        with error:
            status, headers, body = error.code, error.headers, error.read()
    except (urllib.error.URLError, OSError) as error:
        sys.exit(f"HTTPS {method}: {error.reason if isinstance(error, urllib.error.URLError) else error}")
    if status != expected:
        sys.exit(f"HTTPS {method}: ожидался код {expected}, получен {status}")
    return headers, body

request(root + "/config.js", 200)
request(base.rstrip("/"), 404)
_, body = request(base + "?bridge=invalid", 404)
if b"<title>Jitsi Meet</title>" not in body:
    sys.exit("Nginx пока не передаёт запросы в Telemt.")

context = f"tdesktop-web-proxy-bridge-v2\n{domain}\n{prefix}".encode()
capability = encode(hmac.digest(client_secret, context, "sha256"))
headers, document = request(base + "?bridge=" + capability, 200)
bootstrap = re.search(rb'let bootstrap="([A-Za-z0-9_-]{43})"', document)
if not bootstrap or headers.get("Cache-Control") != "no-store":
    sys.exit("Не получена авторизованная страница WEB Proxy.")

endpoint = base + "api/v1/session"
headers, welcome = request(endpoint, 200, "POST", bytes.fromhex("100000000000000101"), {
    "Authorization": "Bearer " + bootstrap[1].decode("ascii"),
    "Content-Type": "application/octet-stream",
})
session = headers.get("X-Session-Token")
if not session:
    sys.exit("Telemt не вернул токен WEB-сеанса.")
request(endpoint, 204, "DELETE", headers={"Authorization": "Bearer " + session})
if welcome[:1] != b"\x11":
    sys.exit("Telemt не вернул кадр WELCOME.")

if mode == "save":
    destination = pathlib.Path(link_path)
    query = urllib.parse.urlencode({"server": domain + "/" + prefix, "secret": encode(b"p" + client_secret)})
    with tempfile.NamedTemporaryFile(mode="w", dir=destination.parent, delete=False) as file:
        file.write("tg://webproxy?" + query + "\n")
        staged = file.name
    os.replace(staged, destination)
print("Jitsi HTTPS и авторизованный WEB-сеанс проверены.")
PY
}

baseline=$(curl --noproxy '*' -fsS --http2 --max-time 10 -o /dev/null -w '%{http_version}' "https://$domain/config.js")
[[ $baseline == 2 ]] || fail 'Публичный HTTPS Jitsi должен поддерживать HTTP/2'
docker exec "$jitsi" grep -Fq "include $nginx_root/nginx-custom/*.conf;" "$nginx_root/nginx/meet.conf" ||
    fail "Эта версия Jitsi не подключает $nginx_root/nginx-custom/*.conf"
docker exec "$jitsi" grep -Eq 'map[[:space:]]+\$http_upgrade[[:space:]]+\$connection_upgrade' "$nginx_config" ||
    fail 'В Nginx Jitsi отсутствует переменная connection_upgrade'
docker exec "$jitsi" nginx -t -c "$nginx_config"
jitsi_compose config --quiet

if [[ -L $INSTALL_DIR || ( -e $INSTALL_DIR && ! -d $INSTALL_DIR ) ]]; then
    fail "Некорректный каталог $INSTALL_DIR"
fi

if [[ ${check:-0} == 0 ]]; then
    exec 9>/run/lock/telemt-web-install.lock
    flock -n 9 || fail 'Уже запущена другая установка Telemt WEB'
fi

secret=''
if [[ -f $proxy_config && ! -L $proxy_config ]]; then
    secret=$(read_secret)
fi
matches_if_present "$proxy_config" render_telemt
matches_if_present "$INSTALL_DIR/compose.yaml" render_compose
matches_if_present "$INSTALL_DIR/Dockerfile" render_dockerfile
matches_if_present "$INSTALL_DIR/.dockerignore" render_dockerignore
matches_if_present "$INSTALL_DIR/public/index.html" render_decoy
matches_if_present "$INSTALL_DIR/public/$base/index.html" render_decoy
matches_if_present "$override" render_override
matches_if_present "$route" render_nginx
has_runtime_route=0
if [[ $nginx_root != /config ]] && docker exec "$jitsi" test -e "$runtime_route"; then
    has_runtime_route=1
    docker exec "$jitsi" cat "$runtime_route" | cmp -s - <(render_nginx) ||
        fail "Найден несовместимый файл $runtime_route внутри $jitsi"
fi
[[ ! -L $INSTALL_DIR/telemt ]] || fail "$INSTALL_DIR/telemt является символической ссылкой"
if [[ -e $INSTALL_DIR/telemt ]]; then
    printf '%s  %s\n' "$BINARY_SHA" "$INSTALL_DIR/telemt" | sha256sum --check --status ||
        fail 'Существующий бинарник не совпадает с закреплённым релизом Telemt'
fi

has_network=0
if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    has_network=1
    actual=$(docker network inspect -f '{{.Driver}} {{.Internal}} {{range .IPAM.Config}}{{.Subnet}}{{end}}' "$NETWORK")
    [[ $actual == "bridge false $subnet" ]] || fail "Существующая сеть $NETWORK использует другую конфигурацию"
fi
current_ip=$(network_ip "$jitsi")
[[ -z $current_ip || $current_ip == "$nginx_ip" ]] || fail 'У Jitsi другой адрес в сети Telemt'
has_container=0
if docker container inspect "$CONTAINER" >/dev/null 2>&1; then
    has_container=1
    actual=$(docker inspect -f '{{.Config.Image}} {{index .Config.Labels "com.docker.compose.project.working_dir"}} {{json .HostConfig.PortBindings}}' "$CONTAINER")
    [[ $actual == "local/telemt-web:$VERSION $INSTALL_DIR {}" && -f $proxy_config && -f $INSTALL_DIR/compose.yaml ]] ||
        fail "Имя $CONTAINER занято другим контейнером"
fi

if [[ ! -f $INSTALL_DIR/telemt ]] || (( ! has_container )); then
    capacity_path=$INSTALL_DIR
    [[ -d $capacity_path ]] || capacity_path=$(dirname "$INSTALL_DIR")
    free_kib=$(df -Pk "$capacity_path" | awk 'NR == 2 {print $4}')
    if [[ ! $free_kib =~ ^[0-9]+$ ]] || (( free_kib < 102400 )); then
        fail "Для установки нужно не менее 100 МиБ на разделе $capacity_path"
    fi
fi

if [[ ${check:-0} == 1 ]]; then
    if (( has_container )) && [[ -f $route && $current_ip == "$nginx_ip" ]]; then
        verify check
    fi
    printf 'Проверка завершена. Jitsi: %s, адрес WEB Proxy: https://%s/%s/\n' "$jitsi" "$domain" "$base"
    exit 0
fi

staging=''
binary_staging=''
new_network=0
new_attachment=0
new_container=0
new_override=0
new_route=0
new_runtime_route=0
cleanup() {
    local status=$?
    trap - EXIT
    set +e
    if (( status )); then
        if (( new_route )); then
            rm -f -- "$route"
        fi
        if (( new_runtime_route )); then
            docker exec "$jitsi" rm -f -- "$runtime_route"
        fi
        if (( new_route || new_runtime_route )); then
            docker exec "$jitsi" nginx -s reload -c "$nginx_config"
        fi
        if (( new_attachment )); then
            docker network disconnect "$NETWORK" "$jitsi"
        fi
        if (( new_container )); then
            docker rm -f "$CONTAINER"
        fi
        if (( new_network )); then
            docker network rm "$NETWORK"
        fi
        if (( new_override )); then
            rm -f -- "$override"
        fi
    fi
    if [[ -n $staging ]]; then
        rm -f -- "$staging"
    fi
    if [[ -n $binary_staging ]]; then
        rm -f -- "$binary_staging"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Публикуем конфигурационные файлы атомарно в пределах одной файловой системы.
write_new() {
    local file=$1 mode=$2 renderer=$3
    [[ ! -e $file ]] || return 0
    staging=$(mktemp "$(dirname "$file")/.telemt-web.XXXXXX")
    "$renderer" >"$staging"
    chmod "$mode" "$staging"
    mv -T -- "$staging" "$file"
    staging=''
}

install -d -m 0700 "$INSTALL_DIR"
install -d -m 0755 "$INSTALL_DIR/public/$base"
if [[ ! -f $INSTALL_DIR/telemt ]]; then
    staging=$(mktemp "$INSTALL_DIR/.release.XXXXXX")
    curl --noproxy '*' --fail --silent --show-error --location --retry 2 --max-time 90 \
        --proto '=https' --proto-redir '=https' \
        "https://github.com/telemt/telemt/releases/download/$VERSION/$ASSET" -o "$staging"
    printf '%s  %s\n' "$ARCHIVE_SHA" "$staging" | sha256sum --check --status ||
        fail 'Контрольная сумма архива Telemt не совпала'
    binary_staging=$(mktemp "$INSTALL_DIR/.binary.XXXXXX")
    tar -xOf "$staging" telemt >"$binary_staging"
    printf '%s  %s\n' "$BINARY_SHA" "$binary_staging" | sha256sum --check --status ||
        fail 'Контрольная сумма бинарника Telemt не совпала'
    chmod 0755 "$binary_staging"
    mv -T -- "$binary_staging" "$INSTALL_DIR/telemt"
    binary_staging=''
    rm -f -- "$staging"
    staging=''
fi

[[ -n $secret ]] || secret=$(openssl rand -hex 16)
write_new "$proxy_config" 0600 render_telemt
write_new "$INSTALL_DIR/compose.yaml" 0644 render_compose
write_new "$INSTALL_DIR/Dockerfile" 0644 render_dockerfile
write_new "$INSTALL_DIR/.dockerignore" 0644 render_dockerignore
write_new "$INSTALL_DIR/public/index.html" 0644 render_decoy
write_new "$INSTALL_DIR/public/$base/index.html" 0644 render_decoy

if (( ! has_network )); then
    docker network create --subnet "$subnet" "$NETWORK" >/dev/null
    new_network=1
fi
if (( has_container )); then
    telemt_compose up -d --no-recreate --no-build
else
    new_container=1
    telemt_compose up -d --build
fi
docker exec "$CONTAINER" /telemt --version | grep -Fx "telemt $VERSION"

if [[ ! -f $override ]]; then
    write_new "$override" 0644 render_override
    new_override=1
fi
jitsi_compose config --quiet
if [[ -z $current_ip ]]; then
    docker network connect --ip "$nginx_ip" --gw-priority -1 "$NETWORK" "$jitsi"
    new_attachment=1
fi
[[ $(network_ip "$jitsi") == "$nginx_ip" ]] || fail 'Jitsi не подключён к сети Telemt'
[[ $(network_ip "$CONTAINER") == "$telemt_ip" ]] || fail 'Telemt не подключён к приватной сети'

if [[ ! -f $route ]]; then
    install -d -m 0755 "$(dirname "$route")"
    write_new "$route" 0644 render_nginx
    new_route=1
fi
if [[ $nginx_root != /config ]] && (( ! has_runtime_route )); then
    new_runtime_route=1
    docker exec -i "$jitsi" sh -c '
        set -eu
        mkdir -p "$(dirname "$1")"
        temporary=$(mktemp "$(dirname "$1")/.telemt-web.XXXXXX")
        trap '\''rm -f -- "$temporary"'\'' EXIT
        cat >"$temporary"
        chmod 0644 "$temporary"
        mv -T -- "$temporary" "$1"
    ' sh "$runtime_route" <"$route"
fi
docker exec "$jitsi" nginx -t -c "$nginx_config"
docker exec "$jitsi" nginx -s reload -c "$nginx_config"

for ((attempt = 1; attempt <= 15; attempt++)); do
    if verify save; then
        printf 'Готово. Приватная ссылка для Telegram сохранена в %s\n' "$link_file"
        exit 0
    fi
    sleep 2
done
fail 'WEB Proxy не прошёл проверку после запуска'
