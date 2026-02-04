#!/usr/bin/env bash
trim_ws() {
  # trim leading/trailing whitespace
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

set -Eeuo pipefail

# DLH-Script V2 — install & update (Nginx/PHP/SSL/WordPress helper)
# - Force IPv4 for apt/curl by default
# - Installs/updates /usr/local/bin/dlh-script.sh (menu) + itself
# - Stores config in /etc/dlh-script/config.env (INSTALL_URL, ROOT_BASE, SSL_EMAIL)
# - Idempotent Nginx configs (removes/rewrites only files it manages)

APP_NAME="DLH-Script V2"
CFG_DIR="/etc/dlh-script"
CFG_FILE="$CFG_DIR/config.env"
BIN_INSTALL="/usr/local/bin/installandupdate.sh"
BIN_MENU="/usr/local/bin/dlh-script.sh"
BIN_DLH="/usr/local/bin/dlh"
BIN_UPDATE="/usr/local/bin/dlh-update"

DEFAULT_ROOT_BASE="/home/www"
DEFAULT_INSTALL_URL="https://raw.githubusercontent.com/duongaitivn/dlh-scriptserver/main/installandupdate.sh"
DEFAULT_MENU_URL="https://raw.githubusercontent.com/duongaitivn/dlh-scriptserver/main/dlh-script.sh"

log(){ echo -e "$*"; }
ok(){ echo -e "[OK] $*"; }
warn(){ echo -e "[CẢNH BÁO] $*"; }
err(){ echo -e "[LỖI] $*" >&2; }
die(){ err "$*"; exit 1; }

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Bạn cần chạy với quyền root (sudo)."; }

force_ipv4_apt(){
  install -d /etc/apt/apt.conf.d
  cat > /etc/apt/apt.conf.d/99force-ipv4 <<'EOF'
Acquire::ForceIPv4 "true";
EOF
}

curl4(){ curl -4 -fsSL "$@"; }

trim_crlf(){ tr -d '\r' | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//'; }

cfg_init(){
  install -d "$CFG_DIR"
  if [[ ! -f "$CFG_FILE" ]]; then
    cat > "$CFG_FILE" <<EOF
# DLH-Script config
INSTALL_URL="$DEFAULT_INSTALL_URL"
MENU_URL="$DEFAULT_MENU_URL"
ROOT_BASE="$DEFAULT_ROOT_BASE"
SSL_EMAIL=""
EOF
  fi
  sed -i 's/\r$//' "$CFG_FILE" || true
  # shellcheck disable=SC1090
  source "$CFG_FILE"
  : "${INSTALL_URL:=$DEFAULT_INSTALL_URL}"
  : "${MENU_URL:=$DEFAULT_MENU_URL}"
  : "${ROOT_BASE:=$DEFAULT_ROOT_BASE}"
  : "${SSL_EMAIL:=}"
}

cfg_set_kv(){
  local key="$1" val="$2"
  val="$(printf "%s" "$val" | trim_crlf)"
  if grep -qE "^${key}=" "$CFG_FILE"; then
    local esc
    esc="$(printf "%s" "$val" | sed 's/[&/\\]/\\&/g')"
    sed -i "s#^${key}=.*#${key}=\"${esc}\"#g" "$CFG_FILE"
  else
    printf '%s="%s"\n' "$key" "$val" >> "$CFG_FILE"
  fi
}

normalize_url(){
  local u="$1"
  u="$(printf "%s" "$u" | trim_crlf)"
  u="${u%\"}"; u="${u#\"}"
  u="${u%\'}"; u="${u#\'}"
  printf "%s" "$u"
}

download_to(){
  local url="$1" out="$2"
  url="$(normalize_url "$url")"
  [[ -n "$url" ]] || return 1
  ok "Tải từ: $url"
  curl4 "$url" -o "$out" || return 1
  chmod +x "$out"
}

NGX_CONF_DIR="/etc/nginx/conf.d"
NGX_SNIP_DIR="/etc/nginx/snippets"

DLH_SEC="$NGX_CONF_DIR/00-dlh-security.conf"
DLH_GZIP="$NGX_CONF_DIR/01-dlh-gzip.conf"
DLH_LIMIT="$NGX_CONF_DIR/10-dlh-limit-zones.conf"
DLH_SNIP="$NGX_SNIP_DIR/dlh-basic-antibot.conf"

nginx_installed(){ command -v nginx >/dev/null 2>&1; }

nginx_cleanup_old_conflicts(){
  for f in "$NGX_CONF_DIR/00-security.conf" "$NGX_CONF_DIR/01-gzip.conf" "$NGX_CONF_DIR/10-limit-zones.conf"; do
    if [[ -f "$f" ]]; then
      mv -f "$f" "$f.bak.$(date +%s)" || true
      warn "Đã backup file cũ: $f -> $f.bak.*"
    fi
  done

  for f in "$DLH_SEC" "$DLH_GZIP" "$DLH_LIMIT"; do
    [[ -f "$f" ]] && rm -f "$f"
  done

  install -d "$NGX_SNIP_DIR"
  if [[ -f "$NGX_SNIP_DIR/basic-antibot.conf" ]]; then
    mv -f "$NGX_SNIP_DIR/basic-antibot.conf" "$NGX_SNIP_DIR/basic-antibot.conf.bak.$(date +%s)" || true
    warn "Đã backup snippet cũ: basic-antibot.conf -> .bak.*"
  fi

  if [[ -d /etc/nginx/sites-enabled ]]; then
    sed -i 's#/etc/nginx/snippets/basic-antibot\.conf#/etc/nginx/snippets/dlh-basic-antibot\.conf#g' /etc/nginx/sites-enabled/*.conf 2>/dev/null || true
  fi
}

gzip_already_on(){
  grep -RIn --include='*.conf' -E '^\s*gzip\s+on\s*;' /etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/sites-enabled 2>/dev/null | head -n 1 | grep -q .
}

write_nginx_managed_confs(){
  nginx_cleanup_old_conflicts

  cat > "$DLH_SEC" <<'EOF'
# DLH managed: basic security
server_tokens off;

map $http_user_agent $dlh_bad_ua {
  default 0;
  ~*(masscan|nikto|sqlmap|nmap|acunetix|wpscan|python-requests) 1;
}
EOF

  cat > "$DLH_LIMIT" <<'EOF'
# DLH managed: limit zones (unique names)
limit_req_zone  $binary_remote_addr  zone=dlh_perip:10m  rate=5r/s;
limit_req_zone  $binary_remote_addr  zone=dlh_login:10m  rate=1r/s;

limit_conn_zone $binary_remote_addr  zone=dlh_connperip:10m;
EOF

  cat > "$DLH_SNIP" <<'EOF'
# DLH managed: basic antibot snippet

if ($dlh_bad_ua) { return 444; }

limit_conn dlh_connperip 20;
limit_req zone=dlh_perip burst=20 nodelay;
EOF

  if gzip_already_on; then
    warn "Đã phát hiện gzip 'on' ở cấu hình hiện tại -> không tạo $DLH_GZIP"
    rm -f "$DLH_GZIP" 2>/dev/null || true
  else
    cat > "$DLH_GZIP" <<'EOF'
# DLH managed: gzip (only if gzip is not already enabled elsewhere)
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_min_length 1024;
gzip_types
  text/plain
  text/css
  text/xml
  text/javascript
  application/javascript
  application/x-javascript
  application/json
  application/xml
  application/xml+rss
  application/rss+xml
  image/svg+xml;
EOF
  fi
}

install_nginx_php(){
  force_ipv4_apt
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y nginx php-fpm php-cli php-mysql php-curl php-mbstring php-xml php-zip php-gd php-intl unzip curl ca-certificates
  systemctl enable nginx || true
  systemctl enable php8.3-fpm || true
}

apply_nginx_and_test(){
  write_nginx_managed_confs
  nginx -t
  systemctl restart nginx
  ok "Nginx OK."
}

ensure_bins(){
  install -m 755 "$0" "$BIN_INSTALL" || true
  ln -sf "$BIN_MENU" "$BIN_DLH"
  ln -sf "$BIN_INSTALL" "$BIN_UPDATE"
}

update_from_config(){
  cfg_init
  local install_url menu_url
  install_url="$(normalize_url "$INSTALL_URL")"
  menu_url="$(normalize_url "$MENU_URL")"
  ok "INSTALL_URL hiện tại: $install_url"
  ok "MENU_URL hiện tại   : $menu_url"

  local tmpi tmpm
  tmpi="$(mktemp)"
  tmpm="$(mktemp)"

  if ! download_to "$install_url" "$tmpi"; then
    rm -f "$tmpi" "$tmpm"
    die "Không tải được INSTALL_URL."
  fi
  if ! download_to "$menu_url" "$tmpm"; then
    rm -f "$tmpi" "$tmpm"
    die "Không tải được MENU_URL."
  fi

  install -m 755 "$tmpi" "$BIN_INSTALL"
  install -m 755 "$tmpm" "$BIN_MENU"
  rm -f "$tmpi" "$tmpm"

  ensure_bins
  ok "Update thành công."
}

do_install(){
  cfg_init
  ok "$APP_NAME — bắt đầu cài đặt"
  ok "ROOT_BASE: $ROOT_BASE"

  install_nginx_php
  apply_nginx_and_test

  update_from_config

  ok "Hoàn tất. Gõ: dlh"
  ok "Cập nhật: dlh-update"
}

do_update(){ update_from_config; }

do_nginx_fix(){
  nginx_installed || die "Chưa có nginx."
  apply_nginx_and_test
}

usage(){
  cat <<EOF
$APP_NAME
Dùng:
  $0 --install
  $0 --update
  $0 --nginx-fix
EOF
}

main(){
  need_root
  local cmd="${1:- --install}"
  case "$cmd" in
    --install) do_install ;;
    --update) do_update ;;
    --nginx-fix) do_nginx_fix ;;
    *) usage; exit 1 ;;
  esac
}

main "$@"
