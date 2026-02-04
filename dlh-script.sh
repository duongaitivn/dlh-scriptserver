#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/dlh-menu.conf"
ROOT_BASE_DEFAULT="/home/www"
PHP_SOCK="/run/php/php8.3-fpm.sock"
ZONE_CONN_DEFAULT="dlh_connperip"
MYSQL_ADMIN_CNF_DEFAULT="/var/lib/dlh/secrets/mysql-admin.cnf"

ensure_apt_ipv4_() {
  mkdir -p /etc/apt/apt.conf.d
  printf 'Acquire::ForceIPv4 "true";\n' > /etc/apt/apt.conf.d/99force-ipv4
}

apt_install_() {
  ensure_apt_ipv4_
  apt-get update -y
  apt-get install -y "$@"
}

is_tty() { [[ -t 1 ]]; }
if is_tty; then
  C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
  C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'; C_CYA=$'\033[36m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GRN=""; C_YEL=""; C_BLU=""; C_CYA=""
fi

hr() { printf "%s\n" "------------------------------------------------------------"; }
clear_screen() { is_tty && clear || true; }

read_tty() {
  local prompt="$1" var=""
  if [[ -r /dev/tty ]]; then
    IFS= read -r -p "$prompt" var </dev/tty || true
  else
    IFS= read -r -p "$prompt" var || true
  fi
  printf "%s" "$var"
}
pause() { read_tty "Nhấn Enter để tiếp tục..."; }

banner() {
  clear_screen
  printf "%s%sDLH-Script V1%s\n" "$C_BOLD" "$C_CYA" "$C_RESET"
  printf "%sMenu webserver cơ bản - bản tối giản 2 file%s\n" "$C_DIM" "$C_RESET"
  hr
}
msg_ok()   { printf "%s[OK]%s %s\n"   "$C_GRN" "$C_RESET" "$*"; }
msg_warn() { printf "%s[CẢNH BÁO]%s %s\n" "$C_YEL" "$C_RESET" "$*"; }
msg_err()  { printf "%s[LỖI]%s %s\n"  "$C_RED" "$C_RESET" "$*"; }

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

load_conf() {
  if [[ -f "$CONF" ]]; then
    source "$CONF" || true
  fi
  ROOT_BASE="${ROOT_BASE:-$ROOT_BASE_DEFAULT}"
  ZONE_CONN="${ZONE_CONN:-$ZONE_CONN_DEFAULT}"
  SSL_EMAIL="${SSL_EMAIL:-}"
  MYSQL_ADMIN_CNF="${MYSQL_ADMIN_CNF:-$MYSQL_ADMIN_CNF_DEFAULT}"
}

save_conf() {
  mkdir -p "$(dirname "$CONF")"
  cat >"$CONF" <<EOF
ROOT_BASE="${ROOT_BASE}"
ZONE_CONN="${ZONE_CONN}"
SSL_EMAIL="${SSL_EMAIL}"
MYSQL_ADMIN_CNF="${MYSQL_ADMIN_CNF}"
EOF
}

# -----------------------------
# Danh sách domain / SSL
# -----------------------------
list_domains_() {
  local -a domains=()
  if [[ -d "$ROOT_BASE" ]]; then
    while IFS= read -r -d '' d; do
      domains+=("$(basename "$d")")
    done < <(find "$ROOT_BASE" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null || true)
  fi

  if [[ "${#domains[@]}" -eq 0 ]]; then
    echo "  (chưa có domain nào trong ${ROOT_BASE})"
    return 1
  fi

  local i=1
  for d in "${domains[@]}"; do
    printf "  %2d) %s\n" "$i" "$d"
    i=$((i+1))
  done
  return 0
}

choose_domain_() {
  # Trả về domain qua stdout. Return 1 nếu không chọn.
  local prompt="${1:-Chọn domain}"
  echo
  echo "[DANH SÁCH DOMAIN]"
  if ! list_domains_; then
    echo
    read_tty "Nhập domain (vd: example.com) (Enter để hủy): "
    local d="${REPLY:-}"
    [[ -n "$d" ]] && echo "$d" && return 0
    return 1
  fi

  echo
  read_tty "${prompt} (nhập số hoặc gõ domain, Enter để hủy): "
  local ans="${REPLY:-}"
  [[ -z "$ans" ]] && return 1

  if [[ "$ans" =~ ^[0-9]+$ ]]; then
    local idx="$ans"
    local picked=""
    picked="$(find "$ROOT_BASE" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sed -n "${idx}p" || true)"
    [[ -n "$picked" ]] || { echo "[LỖI] Số không hợp lệ."; return 1; }
    echo "$picked"
    return 0
  fi

  echo "$ans"
  return 0
}

list_ssl_domains_() {
  echo
  echo "[DANH SÁCH SSL (Let's Encrypt)]"
  if [[ ! -d /etc/letsencrypt/renewal ]]; then
    echo "  (chưa có chứng chỉ nào)"
    return 0
  fi
  local found=0
  for f in /etc/letsencrypt/renewal/*.conf; do
    [[ -f "$f" ]] || continue
    local line
    line="$(grep -E '^[[:space:]]*domains[[:space:]]*=' "$f" 2>/dev/null | head -n1 || true)"
    if [[ -n "$line" ]]; then
      found=1
      local certname
      certname="$(basename "$f" .conf)"
      # domains = a.com, www.a.com
      local doms="${line#*=}"
      doms="$(echo "$doms" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
      printf "  - %s: %s\n" "$certname" "$doms"
    fi
  done
  [[ "$found" -eq 1 ]] || echo "  (chưa có chứng chỉ nào)"
}


ensure_snippets() {
  mkdir -p /etc/nginx/snippets
  [[ -f /etc/nginx/snippets/dlh-block-sensitive.conf ]] || cat >/etc/nginx/snippets/dlh-block-sensitive.conf <<'EOF'
location ~* /\.((?!well-known).)* { deny all; }
location ~* /(\.git|\.svn|\.hg|\.env) { deny all; }
location ~* /(composer\.(json|lock)|package\.json|yarn\.lock) { deny all; }
EOF

  [[ -f /etc/nginx/snippets/dlh-basic-antibot.conf ]] || cat >/etc/nginx/snippets/dlh-basic-antibot.conf <<EOF
limit_conn ${ZONE_CONN} 20;
location = /xmlrpc.php { deny all; }
location = /wp-login.php { try_files \$uri \$uri/ /index.php?\$args; }
EOF
}

nginx_reload() { nginx -t && systemctl reload nginx; }

mysql_try_socket_() { mysql -e "SELECT 1" >/dev/null 2>&1; }
mysql_try_admin_cnf_() { [[ -f "$MYSQL_ADMIN_CNF" ]] || return 1; mysql --defaults-extra-file="$MYSQL_ADMIN_CNF" -e "SELECT 1" >/dev/null 2>&1; }

mysql_ensure_admin_() {
  mkdir -p "$(dirname "$MYSQL_ADMIN_CNF")"
  chmod 700 "$(dirname "$MYSQL_ADMIN_CNF")" 2>/dev/null || true
  if mysql_try_socket_ || mysql_try_admin_cnf_; then return 0; fi

  msg_warn "Chưa có quyền MySQL để thao tác database."
  msg_warn "Nhập user/pass MySQL admin (thường là root). Lưu tại: ${MYSQL_ADMIN_CNF}"
  local u p
  u="$(read_tty "MySQL user: ")"
  p="$(read_tty "MySQL password: ")"
  [[ -n "$u" ]] || { msg_err "User trống."; return 1; }

  cat >"$MYSQL_ADMIN_CNF" <<EOF
[client]
user=${u}
password=${p}
EOF
  chmod 600 "$MYSQL_ADMIN_CNF"
  mysql_try_admin_cnf_ && { msg_ok "Đã lưu MySQL admin creds."; return 0; }
  rm -f "$MYSQL_ADMIN_CNF" || true
  msg_err "Sai user/password MySQL."
  return 1
}

mysql_exec_() {
  local sql="$1"
  if mysql_try_socket_ ; then mysql -e "$sql"; return 0; fi
  mysql_ensure_admin_ || return 1
  mysql --defaults-extra-file="$MYSQL_ADMIN_CNF" -e "$sql"
}

set_ssl_email() {
  local e
  e="$(read_tty "Nhập email mặc định (dùng cho SSL Let's Encrypt): ")"
  [[ -n "$e" ]] || { msg_err "Email trống."; return; }
  SSL_EMAIL="$e"
  save_conf
  msg_ok "Đã lưu email SSL mặc định: $SSL_EMAIL"
}

add_domain() {
  ensure_snippets
  local domain
  domain="$(read_tty "Nhập tên miền (vd: example.com): ")"
  domain="${domain,,}"
  [[ -n "$domain" ]] || { msg_err "Tên miền trống."; return; }

  local webroot="${ROOT_BASE}/${domain}/public_html"
  mkdir -p "$webroot"
  [[ -f "${webroot}/index.php" ]] || echo '<?php echo "OK"; ?>' > "${webroot}/index.php"
  chown -R www-data:www-data "${ROOT_BASE}/${domain}"

  local conf="/etc/nginx/sites-available/${domain}.conf"
  cat >"$conf" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${domain} www.${domain};

  root ${webroot};
  index index.php index.html;

  include /etc/nginx/snippets/dlh-block-sensitive.conf;
  include /etc/nginx/snippets/dlh-basic-antibot.conf;

  location / { try_files \$uri \$uri/ /index.php?\$args; }

  location ~ \.php$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:${PHP_SOCK};
  }
}
EOF

  ln -sf "$conf" "/etc/nginx/sites-enabled/${domain}.conf"
  nginx_reload
  msg_ok "Đã tạo website: ${domain}"
  msg_ok "Webroot: ${webroot}"
}

install_ssl() {
  local domain email
  domain="$(choose_domain_ "Cài SSL cho domain nào")" || return
  domain="${domain,,}"
  domain="$(echo "$domain" | tr -d ' ')"
  [[ -n "$domain" ]] || { msg_err "Tên miền trống."; return; }

  # Email mặc định: hỏi 1 lần, lưu lại
  if [[ -n "${SSL_EMAIL:-}" ]]; then
    email="$SSL_EMAIL"
    msg_ok "Dùng email SSL mặc định: ${email}"
  else
    email="$(read_tty "Nhập email nhận thông báo SSL (lưu lại lần sau): ")" || true
    email="${email:-}"
    [[ -n "$email" ]] || { msg_err "Email trống."; return; }
    SSL_EMAIL="$email"
    save_conf
    msg_ok "Đã lưu email SSL mặc định."
  fi

  apt_install_ certbot python3-certbot-nginx dnsutils

  # Kiểm tra DNS www: ưu tiên dig @1.1.1.1 (chuẩn nhất), fallback getent
  local has_www=0
  if command -v dig >/dev/null 2>&1; then
    local a4 a6
    a4="$(dig +short A "www.${domain}" @1.1.1.1 2>/dev/null | head -n1 || true)"
    a6="$(dig +short AAAA "www.${domain}" @1.1.1.1 2>/dev/null | head -n1 || true)"
    [[ -n "$a4" || -n "$a6" ]] && has_www=1 || has_www=0
  else
    getent ahosts "www.${domain}" >/dev/null 2>&1 && has_www=1 || has_www=0
  fi

  local args=(-d "$domain")
  if [[ "$has_www" -eq 1 ]]; then
    args+=(-d "www.${domain}")
    msg_ok "DNS có www.${domain} -> sẽ xin SSL kèm www"
  else
    msg_warn "DNS thiếu www.${domain} -> chỉ xin SSL cho ${domain}"
  fi

  # --expand để không hỏi Y/n khi đã có cert cũ
  certbot --nginx "${args[@]}" --cert-name "$domain" --expand \
    -m "$email" --agree-tos --non-interactive --redirect || {
      msg_warn "Cài SSL thất bại. Hãy kiểm tra DNS/Cloudflare và đảm bảo port 80 truy cập được."
      return
    }

  systemctl enable --now certbot.timer || true

  # Bật HTTP/2 cho server block SSL
  sed -i 's/listen 443 ssl;/listen 443 ssl http2;/g' /etc/nginx/sites-enabled/*.conf 2>/dev/null || true
  sed -i 's/listen \[::\]:443 ssl;/listen [::]:443 ssl http2;/g' /etc/nginx/sites-enabled/*.conf 2>/dev/null || true

  nginx_test_reload_
  msg_ok "Hoàn tất cài SSL (Let\'s Encrypt)."
}


delete_domain() {
  local domain ans
  domain="$(read_tty "Nhập tên miền cần XÓA (vd: example.com): ")"
  domain="${domain,,}"
  [[ -n "$domain" ]] || { msg_err "Tên miền trống."; return; }

  msg_warn "Sẽ xóa vhost + webroot (tuỳ chọn SSL/DB)."
  ans="$(read_tty "Xác nhận xóa ${domain}? (gõ YES để tiếp tục): ")"
  [[ "$ans" == "YES" ]] || { msg_warn "Hủy."; return; }

  rm -f "/etc/nginx/sites-enabled/${domain}.conf" 2>/dev/null || true
  rm -f "/etc/nginx/sites-available/${domain}.conf" 2>/dev/null || true
  rm -rf "${ROOT_BASE}/${domain}" 2>/dev/null || true
  nginx -t >/dev/null 2>&1 && systemctl reload nginx || true

  ans="$(read_tty "Xóa SSL certificate của ${domain}? (y/N): ")"
  if [[ "$ans" =~ ^[Yy]$ ]] && command -v certbot >/dev/null 2>&1; then
    certbot delete --cert-name "$domain" --non-interactive >/dev/null 2>&1 || true
    msg_ok "Đã xóa cert (nếu có)."
  fi

  ans="$(read_tty "Xóa DATABASE? (y/N): ")"
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    local db
    db="$(read_tty "Nhập tên database cần xóa: ")"
    [[ -n "$db" ]] && mysql_exec_ "DROP DATABASE IF EXISTS \`${db}\`;" && msg_ok "Đã xóa DB: $db" || true
  fi

  msg_ok "Đã xóa domain: $domain"
}

nginx_tools() {
  banner
  echo "${C_BOLD}nginx -t${C_RESET}"
  nginx -t || true
  echo
  echo "${C_BOLD}Trạng thái nginx/php-fpm${C_RESET}"
  systemctl status nginx php8.3-fpm --no-pager || true
  hr
  pause
}

set_root_base() {
  local v
  v="$(read_tty "ROOT_BASE (hiện tại: ${ROOT_BASE}): ")"
  [[ -n "$v" ]] && ROOT_BASE="$v"
  save_conf
  msg_ok "ROOT_BASE=${ROOT_BASE}"
}

run_update() {
  if command -v webserver-update >/dev/null 2>&1; then
    webserver-update
    msg_ok "Đã update."
  else
    msg_err "Chưa có webserver-update."
  fi
}

menu_domain_ssl() {
  while true; do
    banner
    printf "%s%s[TÊN MIỀN / SSL]%s\n" "$C_BOLD" "$C_BLU" "$C_RESET"
    echo "1) Thêm tên miền"
    echo "2) Cài SSL"
    echo "3) Xóa tên miền"
    echo "4) Thiết lập email SSL mặc định"
    echo "5) Danh sách domain đã thêm"
    echo "6) Danh sách domain đang dùng SSL"
    echo "0) Quay lại"
    hr
    case "$(read_tty "Chọn: ")" in
      1) add_domain; pause ;;
      2) install_ssl; pause ;;
      3) delete_domain; pause ;;
      4) set_ssl_email; pause ;;
      5) list_domains_; pause ;;
      6) list_ssl_domains_; pause ;;
      0) return ;;
      *) msg_warn "Sai lựa chọn."; pause ;;
    esac
  done
}

menu_system() {
  while true; do
    banner
    printf "%s%s[HỆ THỐNG / CÔNG CỤ]%s\n" "$C_BOLD" "$C_BLU" "$C_RESET"
    echo "1) Công cụ Nginx"
    echo "2) Update script từ GitHub"
    echo "3) Đổi ROOT_BASE"
    echo "0) Quay lại"
    hr
    case "$(read_tty "Chọn: ")" in
      1) nginx_tools ;;
      2) run_update; pause ;;
      3) set_root_base; pause ;;
      0) return ;;
      *) msg_warn "Sai lựa chọn."; pause ;;
    esac
  done
}

main_menu() {
  while true; do
    banner
    echo "1) Tên miền / SSL"
    echo "2) Hệ thống / Công cụ"
    echo "0) Thoát"
    hr
    case "$(read_tty "Chọn: ")" in
      1) menu_domain_ssl ;;
      2) menu_system ;;
      0) exit 0 ;;
      *) msg_warn "Sai lựa chọn."; pause ;;
    esac
  done
}

load_conf
main_menu
