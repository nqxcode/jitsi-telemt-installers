#!/usr/bin/env bash
set -euo pipefail

cd -- "$(dirname -- "${BASH_SOURCE[0]}")"

cat <<'HEADER'
#!/usr/bin/env bash
# Сгенерировано командой bash build-installer.sh > install.sh.

run_embedded_telemt() {
    bash -s -- "$@" <<'EMBEDDED_TELEMT_INSTALLER'
HEADER
cat telemt-web-install.sh
cat <<'FOOTER'
EMBEDDED_TELEMT_INSTALLER
}

with_telemt=1

FOOTER
sed '1d' jitsi-install.sh
