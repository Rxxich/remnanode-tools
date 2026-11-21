#!/usr/bin/env bash
set -Eeuo pipefail

KIT_REPO="${KIT_REPO:-Rxxich/remnanode-tools}"
KIT_REF="${KIT_REF:-main}"
KIT_DIR="${KIT_DIR:-/opt/remnanode-tools}"
KIT_SHA256="${KIT_SHA256:-}"
KIT_NO_RUN="${KIT_NO_RUN:-0}"
KIT_BINS="/usr/local/bin/rnt /usr/local/bin/remnanode-tools"

if [ -t 1 ]; then
    R=$'\e[0m'; B=$'\e[1m'; A=$'\e[38;5;45m'; G=$'\e[38;5;114m'; E=$'\e[38;5;203m'; D=$'\e[38;5;245m'
else
    R=""; B=""; A=""; G=""; E=""; D=""
fi
say()  { printf '  %s•%s %s\n' "$A" "$R" "$*"; }
good() { printf '  %s✓%s %s\n' "$G" "$R" "$*"; }
fail() { printf '  %s✗%s %s\n' "$E" "$R" "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || fail "Нужен root. Запусти: sudo bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/$KIT_REPO/$KIT_REF/install.sh)\""
[[ "$KIT_REPO" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || fail "KIT_REPO некорректен: $KIT_REPO"
[[ "$KIT_REF" =~ ^[A-Za-z0-9._/-]+$ && "$KIT_REF" != *..* ]] || fail "KIT_REF некорректен: $KIT_REF"
[[ "$KIT_DIR" =~ ^/[A-Za-z0-9._/-]+$ && "$KIT_DIR" != *..* && "$KIT_DIR" != "/" ]] || fail "KIT_DIR некорректен: $KIT_DIR"
[ -r /etc/os-release ] || fail "Не найден /etc/os-release"
# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in debian|ubuntu) ;; *) fail "Нужен Debian или Ubuntu (сейчас: ${PRETTY_NAME:-?})" ;; esac

printf '\n  %s%sremnanode-tools%s %s— установка из %s @ %s%s\n\n' "$B" "$A" "$R" "$D" "$KIT_REPO" "$KIT_REF" "$R"

need=()
command -v curl >/dev/null || need+=(curl)
command -v tar  >/dev/null || need+=(tar)
command -v gzip >/dev/null || need+=(gzip)
[ -f /etc/ssl/certs/ca-certificates.crt ] || need+=(ca-certificates)
if [ "${#need[@]}" -gt 0 ]; then
    say "Ставлю: ${need[*]}"
    DEBIAN_FRONTEND=noninteractive apt-get -qq -o DPkg::Lock::Timeout=180 update >/dev/null
    DEBIAN_FRONTEND=noninteractive apt-get -y -qq -o DPkg::Lock::Timeout=180 install "${need[@]}" >/dev/null
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
URL="https://codeload.github.com/$KIT_REPO/tar.gz/$KIT_REF"
say "Скачиваю $URL"
curl -fsSL --proto '=https' --proto-redir '=https' --retry 3 --max-time 60 "$URL" -o "$WORK/kit.tar.gz" \
    || fail "Не удалось скачать архив (сеть, имя репозитория или ветки?)"

if [ -n "$KIT_SHA256" ]; then
    got="$(sha256sum "$WORK/kit.tar.gz" | awk '{print $1}')"
    [ "${got,,}" = "${KIT_SHA256,,}" ] || fail "SHA-256 не совпал: ждали $KIT_SHA256, получили $got"
    good "SHA-256 совпал"
fi

tar -tzf "$WORK/kit.tar.gz" >"$WORK/list" || fail "Архив повреждён"
if grep -qE '(^/|(^|/)\.\.(/|$))' "$WORK/list"; then fail "В архиве недопустимые пути"; fi
mkdir -p "$WORK/src"
tar -xzf "$WORK/kit.tar.gz" -C "$WORK/src" --strip-components=1 --no-same-owner --no-same-permissions
for f in remnanode-tools.sh lib/core.sh lib/ui.sh modules/node.sh; do
    [ -f "$WORK/src/$f" ] || fail "В архиве нет $f — это не remnanode-tools?"
done

STAGE="$KIT_DIR.new.$$"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -a "$WORK/src/remnanode-tools.sh" "$WORK/src/install.sh" "$WORK/src/lib" "$WORK/src/modules" "$STAGE/"
[ -d "$WORK/src/docs" ] && cp -a "$WORK/src/docs" "$STAGE/"
[ -f "$WORK/src/README.md" ] && cp -a "$WORK/src/README.md" "$STAGE/"
echo "$KIT_REF" >"$STAGE/.ref"
chown -R root:root "$STAGE"
chmod -R u=rwX,go=rX "$STAGE"
chmod 755 "$STAGE/remnanode-tools.sh" "$STAGE/install.sh"

if [ -d "$KIT_DIR" ]; then
    rm -rf "$KIT_DIR.old"
    mv "$KIT_DIR" "$KIT_DIR.old"
fi
mv "$STAGE" "$KIT_DIR"
rm -rf "$KIT_DIR.old"
for b in $KIT_BINS; do ln -sfn "$KIT_DIR/remnanode-tools.sh" "$b"; done
good "remnanode-tools установлен в $KIT_DIR, команда: ${B}rnt${R}"

[ "$KIT_NO_RUN" = "1" ] && exit 0
trap - EXIT
rm -rf "$WORK"
if ( : </dev/tty ) 2>/dev/null; then
    exec bash "$KIT_DIR/remnanode-tools.sh" "$@" </dev/tty
fi
exec bash "$KIT_DIR/remnanode-tools.sh" "$@"
