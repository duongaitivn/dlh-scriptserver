#!/usr/bin/env bash
trim_ws() {
  # trim leading/trailing whitespace
  local s="$*"
  s="${s#"${s%%[![:space:]]*}"}"
  s="${s%"${s##*[![:space:]]}"}"
  printf '%s' "$s"
}

DEFAULT_MENU_URL="https://raw.githubusercontent.com/duongaitivn/dlh-scriptserver/main/dlh-script.sh"
DEFAULT_INSTALL_URL="https://raw.githubusercontent.com/duongaitivn/dlh-scriptserver/main/installandupdate.sh"
set -Eeuo pipefail

APP="DLH-Script V2"
CFG_DIR="/etc/dlh-script"
CFG_FILE="$CFG_DIR/config.env"

NGX_SITES_AVAIL="/etc/nginx/sites-available"
NGX_SITES_EN="/etc/nginx/sites-enabled"
ROOT_BASE_DEFAULT="/home/www"

log(){ echo -e "$*"; }
ok(){ echo -e "[OK] $*"; }
warn(){ echo -e "[CẢNH BÁO] $*"; }
err(){ echo -e "[LỖI] $*" >&2; }
pause(){ read -r -p "Nhấn Enter để tiếp tục..." _; }

need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || { err "Bạn cần chạy với quyền root (sudo)."; exit 1; }; }

trim_crlf(){ tr -d '\r' | sed 's/^[[:space:]]\+//; s/[[:space:]]\+$//'; }

cfg_init(){
  install -d "$CFG_DIR"
  if [[ ! -f "$CFG_FILE" ]]; then
    cat > "$CFG_FILE" <<EOF
INSTALL_URL="https://raw.githubusercontent.com/duongaitivn/dlh-scriptserver/main/installandupdate.sh"
MENU_URL="https://raw.githubusercontent.com/duongaitivn/dlh-scriptserver/main/dlh-script.sh"
ROOT_BASE="$ROOT_BASE_DEFAULT"
SSL_EMAIL=""
EOF
  fi
  sed -i 's/\r$//' "$CFG_FILE" || true
  # shellcheck disable=SC1090
  source "$CFG_FILE"
  : "${ROOT_BASE:=$ROOT_BASE_DEFAULT}"
  : "${SSL_EMAIL:=}"
  : "${INSTALL_URL:=}"
  : "${MENU_URL:=}"
}

cfg_set(){
  local k="$1" v="$2"
  v="$(printf "%s" "$v" | trim_crlf)"
  if grep -qE "^${k}=" "$CFG_FILE"; then
    local esc
    esc="$(printf "%s" "$v" | sed 's/[&/\\]/\\&/g')"
    sed -i "s#^${k}=.*#${k}=\"${esc}\"#g" "$CFG_FILE"
  else
    printf '%s="%s"\n' "$k" "$v" >> "$CFG_FILE"
  fi
  # shellcheck disable=SC1090
  source "$CFG_FILE"
}

read_tty(){
  local prompt="$1" default="${2:-}"
  local ans
  if [[ -n "$default" ]]; then
    read -r -p "$prompt [$default]: " ans </dev/tty || true
    ans="${ans:-$default}"
  else
    read -r -p "$prompt: " ans </dev/tty || true
  fi
  printf "%s" "$ans" | trim_crlf
}

domain_root(){ local d="$1"; printf "%s/%s/public_html" "$ROOT_BASE" "$d"; }

domain_exists(){ local d="$1"; [[ -d "$(domain_root "$d")" ]] || [[ -f "$NGX_SITES_AVAIL/$d.conf" ]]; }

list_domains(){
  if [[ -d "$ROOT_BASE" ]]; then
    find "$ROOT_BASE" -mindepth 2 -maxdepth 2 -type d -name public_html 2>/dev/null       | awk -F/ '{print $(NF-1)}' | sort -u
  fi
}

list_ssl_domains(){
  if [[ -d /etc/letsencrypt/live ]]; then
    ls -1 /etc/letsencrypt/live 2>/dev/null | grep -vE '^README$' | sort -u || true
  fi
}

dns_has_host(){ local host="$1"; getent ahosts "$host" >/dev/null 2>&1; }

ensure_dirs(){
  install -d "$NGX_SITES_AVAIL" "$NGX_SITES_EN"
  install -d "$ROOT_BASE"
}

nginx_reload(){ nginx -t && systemctl reload nginx; }

nginx_write_vhost(){
  local d="$1" root
  root="$(domain_root "$d")"
  ensure_dirs
  install -d "$root"
  cat > "$NGX_SITES_AVAIL/$d.conf" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name $d;

  root $root;
  index index.php index.html;

  include /etc/nginx/snippets/dlh-basic-antibot.conf;

  location / {
    try_files \$uri \$uri/ /index.php?\$args;
  }

  location ~ \.php\$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:/run/php/php8.3-fpm.sock;
  }
}
EOF
  ln -sf "$NGX_SITES_AVAIL/$d.conf" "$NGX_SITES_EN/$d.conf"
  nginx_reload
  ok "Đã tạo vhost + thư mục: $root"
}

menu_add_domain(){
  cfg_init
  local d
  d="$(read_tty "Nhập tên miền (vd: example.com)")"
  [[ -n "$d" ]] || { warn "Bạn chưa nhập tên miền."; return; }
  if domain_exists "$d"; then
    warn "Tên miền đã tồn tại: $d"
    return
  fi
  nginx_write_vhost "$d"
}

ensure_certbot(){
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y certbot python3-certbot-nginx
}

ssl_build_domains(){
  local d="$1"
  local domains=("$d")
  local www="www.$d"
  if dns_has_host "$www"; then
    ok "DNS có $www -> sẽ xin SSL kèm www"
    domains+=("$www")
  else
    warn "DNS KHÔNG có $www (NXDOMAIN) -> tự bỏ www, chỉ xin SSL cho $d"
  fi
  printf "%s\n" "${domains[@]}"
}

ssl_apply(){
  cfg_init
  local pick="$1"
  [[ -n "$pick" ]] || { warn "Bạn chưa nhập tên miền."; return; }

  ensure_certbot

  local email="$SSL_EMAIL"
  if [[ -z "$email" ]]; then
    email="$(read_tty "Nhập email nhận thông báo SSL")"
    [[ -n "$email" ]] || { err "Email trống."; return; }
    cfg_set "SSL_EMAIL" "$email"
    ok "Đã lưu email SSL mặc định: $SSL_EMAIL"
  else
    ok "Dùng email SSL mặc định: $email"
  fi

  mapfile -t ds < <(ssl_build_domains "$pick")
  local args=()
  for x in "${ds[@]}"; do args+=("-d" "$x"); done

  if [[ -f "/etc/letsencrypt/renewal/${pick}.conf" ]]; then
    ok "Phát hiện cert đã tồn tại -> dùng --expand"
    certbot --nginx --agree-tos -m "$email" --no-eff-email --redirect --expand "${args[@]}" || {
      warn "SSL thất bại. Kiểm tra DNS/Cloudflare và port 80."
      return
    }
  else
    certbot --nginx --agree-tos -m "$email" --no-eff-email --redirect "${args[@]}" || {
      warn "SSL thất bại. Kiểm tra DNS/Cloudflare và port 80."
      return
    }
  fi
  ok "Cài SSL xong."
}

menu_ssl(){
  cfg_init
  local domains=()
  while IFS= read -r d; do [[ -n "$d" ]] && domains+=("$d"); done < <(list_domains || true)

  echo "Danh sách domain đã thêm:"
  if [[ ${#domains[@]} -eq 0 ]]; then
    echo "  (chưa có)"
  else
    local i=1
    for d in "${domains[@]}"; do
      echo "  $i) $d"
      i=$((i+1))
    done
  fi
  echo

  local pick
  pick="$(read_tty "Cài SSL cho domain nào (nhập số hoặc gõ domain, Enter để hủy)" "")"
  [[ -n "$pick" ]] || return

  if [[ "$pick" =~ ^[0-9]+$ ]] && [[ ${#domains[@]} -gt 0 ]]; then
    local idx=$((pick-1))
    if [[ $idx -ge 0 && $idx -lt ${#domains[@]} ]]; then
      pick="${domains[$idx]}"
    else
      err "Số không hợp lệ."
      return
    fi
  fi

  ssl_apply "$pick"
}

menu_delete_domain(){
  cfg_init
  local d
  d="$(read_tty "Nhập tên miền cần xóa (vd: example.com)")"
  [[ -n "$d" ]] || return

  local root
  root="$(domain_root "$d")"

  warn "Sẽ xóa:"
  echo " - Vhost: $NGX_SITES_AVAIL/$d.conf và symlink sites-enabled"
  echo " - Web root: $root"
  echo " - SSL (nếu có): /etc/letsencrypt/live/$d"
  local yn
  yn="$(read_tty "Bạn chắc chắn muốn xóa? (gõ YES để xác nhận)" "")"
  [[ "$yn" == "YES" ]] || { warn "Hủy."; return; }

  rm -f "$NGX_SITES_EN/$d.conf" "$NGX_SITES_AVAIL/$d.conf" || true
  [[ -d "$root" ]] && rm -rf "$root" || true

  if [[ -d "/etc/letsencrypt/live/$d" ]]; then
    certbot delete --cert-name "$d" -n || true
  fi

  nginx_reload || true
  ok "Đã xóa domain: $d"
}

menu_set_ssl_email(){
  cfg_init
  local e
  e="$(read_tty "Nhập email SSL mặc định")"
  [[ -n "$e" ]] || { warn "Email trống."; return; }
  cfg_set "SSL_EMAIL" "$e"
  ok "Đã lưu SSL_EMAIL: $SSL_EMAIL"
}

menu_list_domains(){
  cfg_init
  echo "Domain đã thêm (theo $ROOT_BASE/*/public_html):"
  list_domains | sed 's/^/ - /' || echo " (chưa có)"
  pause
}

menu_list_ssl(){
  echo "Domain đang có SSL (theo /etc/letsencrypt/live):"
  list_ssl_domains | sed 's/^/ - /' || echo " (chưa có)"
  pause
}

menu_system(){
  cfg_init
  while true; do
    clear || true
    echo "$APP"
    echo "---------------------------------------------"
    echo "[HỆ THỐNG / CÔNG CỤ]"
    echo "1) Kiểm tra Nginx (test/status)"
    echo "2) Cập nhật script từ GitHub (dlh-update)"
    echo "3) Thiết lập URL cập nhật (INSTALL_URL/MENU_URL)"
    echo "4) Thiết lập thư mục web gốc (ROOT_BASE)"
    echo "0) Quay lại"
    echo "---------------------------------------------"
    local c
    c="$(read_tty "Chọn" "")"
    case "$c" in
      1) nginx -t && systemctl status nginx --no-pager | head -n 30 || true; pause ;;
      2) dlh-update || true; pause ;;
      3)
        local iu mu
        iu="$(read_tty "INSTALL_URL" "$INSTALL_URL")"
        mu="$(read_tty "MENU_URL" "$MENU_URL")"
        cfg_set "INSTALL_URL" "$iu"
        cfg_set "MENU_URL" "$mu"
        ok "Đã lưu URL."
        pause
        ;;
      4)
        local rb
        rb="$(read_tty "ROOT_BASE" "$ROOT_BASE")"
        cfg_set "ROOT_BASE" "$rb"
        ok "Đã lưu ROOT_BASE: $ROOT_BASE"
        pause
        ;;
      0) return ;;
      *) ;;
    esac
  done
}

main_menu(){
  cfg_init
  while true; do
    clear || true
    echo "$APP"
    echo "Menu webserver cơ bản — bản tối giản 2 file"
    echo "---------------------------------------------"
    echo "[TÊN MIỀN / SSL]"
    echo "1) Thêm tên miền"
    echo "2) Cài SSL"
    echo "3) Xóa tên miền"
    echo "4) Thiết lập email SSL mặc định"
    echo "5) Danh sách domain đã thêm"
    echo "6) Danh sách domain đang dùng SSL"
    echo "---------------------------------------------"
    echo "[HỆ THỐNG]"
    echo "9) Hệ thống / công cụ"
    echo "0) Thoát"
    echo "---------------------------------------------"
    local c
    c="$(read_tty "Chọn" "")"
    case "$c" in
      1) menu_add_domain; pause ;;
      2) menu_ssl; pause ;;
      3) menu_delete_domain; pause ;;
      4) menu_set_ssl_email; pause ;;
      5) menu_list_domains ;;
      6) menu_list_ssl ;;
      9) menu_system ;;
      0) exit 0 ;;
      *) ;;
    esac
  done
}

need_root
main_menu
