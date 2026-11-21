#!/usr/bin/env bash
# Сгенерировано командой bash build-installer.sh > install.sh.

run_embedded_telemt() {
    bash -s -- "$@" <<'EMBEDDED_TELEMT_INSTALLER'
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
EMBEDDED_TELEMT_INSTALLER
}

with_telemt=1

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
