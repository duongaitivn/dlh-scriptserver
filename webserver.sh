#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# DLH-Script V1 — Webserver Basic Installer (Ubuntu 24.04 / 1GB RAM)
# - Nginx + PHP-FPM 8.3
# - UFW + Fail2ban + Swap 2G
# - gzip (skip if already enabled) + anti-bot + rate-limit zones
# - logrotate
# - Installs "dlh" menu (Vietnamese UI)
# - Installs "webserver-update" to self-update from GitHub raw URL
#
# NOTE:
# - Default webroot base: /home/www
#
# Run:
#   curl -fsSL <RAW>/webserver.sh | sudo INSTALL_URL="<RAW>/webserver.sh" bash
# =========================================================

CONF="/etc/webserver-installer.conf"
INSTALL_URL="${INSTALL_URL:-}"
ZONE_CONN="dlh_connperip"
DEFAULT_ROOT_BASE="/home/www"

need_root() { [[ "${EUID}" -eq 0 ]] || { echo "ERROR: run with sudo"; exit 1; }; }

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "$@"
}

write_file() {
  local path="$1" content="$2"
  mkdir -p "$(dirname "$path")"
  printf "%s" "$content" > "$path"
}

save_conf() {
  write_file "$CONF" \
"INSTALL_URL=\"${INSTALL_URL}\"
ZONE_CONN=\"${ZONE_CONN}\"
DEFAULT_ROOT_BASE=\"${DEFAULT_ROOT_BASE}\"
"
}

ensure_ufw() {
  command -v ufw >/dev/null 2>&1 || apt_install ufw
  ufw default deny incoming || true
  ufw default allow outgoing || true
  ufw allow OpenSSH || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw --force enable || true
}

ensure_fail2ban() {
  command -v fail2ban-client >/dev/null 2>&1 || apt_install fail2ban
  systemctl enable --now fail2ban

  if [[ ! -f /etc/fail2ban/jail.local ]]; then
    write_file "/etc/fail2ban/jail.local" \
"[sshd]
enabled = true
maxretry = 5
findtime = 10m
bantime = 2h
"
  fi
  systemctl restart fail2ban
}

ensure_swap_2g() {
  swapon --show | grep -q '^/' && return 0
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  write_file "/etc/sysctl.d/99-swappiness.conf" "vm.swappiness=10
"
  sysctl -p /etc/sysctl.d/99-swappiness.conf >/dev/null || true
}

ensure_nginx_php() {
  apt_install nginx
  apt_install php-fpm php-cli php-mysql php-curl php-mbstring php-xml php-zip php-gd php-intl
  systemctl enable --now nginx
  systemctl enable --now php8.3-fpm

  # PHP-FPM tuning for 1GB
  local pool="/etc/php/8.3/fpm/pool.d/www.conf"
  if [[ -f "$pool" ]]; then
    sed -i 's/^pm = .*/pm = ondemand/' "$pool" || true
    sed -i 's/^;*pm\.max_children = .*/pm.max_children = 8/' "$pool" || true
    sed -i 's/^;*pm\.process_idle_timeout = .*/pm.process_idle_timeout = 10s/' "$pool" || true
    sed -i 's/^;*pm\.max_requests = .*/pm.max_requests = 300/' "$pool" || true
  fi
  systemctl restart php8.3-fpm
}

gzip_already_enabled_elsewhere() {
  local hits=""
  hits="$(grep -RIn "^\s*gzip\s\+on\s*;" /etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/sites-enabled 2>/dev/null \
    | grep -v "/etc/nginx/conf.d/01-gzip.conf" || true)"
  [[ -n "$hits" ]]
}

disable_our_gzip_conf() {
  if [[ -f /etc/nginx/conf.d/01-gzip.conf ]]; then
    mv /etc/nginx/conf.d/01-gzip.conf /etc/nginx/conf.d/01-gzip.conf.off
  fi
  return 0
}

ensure_limit_zones() {
  write_file "/etc/nginx/conf.d/10-limit-zones.conf" \
"limit_req_zone \$binary_remote_addr zone=perip:10m rate=5r/s;
limit_req_zone \$binary_remote_addr zone=login:10m rate=1r/s;
limit_conn_zone \$binary_remote_addr zone=${ZONE_CONN}:10m;
"
}

write_nginx_global_conf() {
  write_file "/etc/nginx/conf.d/00-security.conf" \
"server_tokens off;

map \$http_user_agent \$bad_ua {
  default 0;
  ~*\"(masscan|nikto|sqlmap|nmap|acunetix|wpscan|python-requests)\" 1;
}
"

  if gzip_already_enabled_elsewhere; then
    echo "INFO: Existing gzip detected -> skip creating /etc/nginx/conf.d/01-gzip.conf"
    disable_our_gzip_conf
  else
    write_file "/etc/nginx/conf.d/01-gzip.conf" \
"gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_min_length 1024;
gzip_types
  text/plain
  text/css
  application/json
  application/javascript
  application/xml
  image/svg+xml
  font/ttf
  font/otf
  font/woff
  font/woff2;
"
  fi

  ensure_limit_zones
  mkdir -p /etc/nginx/snippets

  write_file "/etc/nginx/snippets/block-sensitive.conf" \
"location ~* /\\.((?!well-known).)* { deny all; }
location ~* /(\\.git|\\.svn|\\.hg|\\.env) { deny all; }
location ~* /(composer\\.(json|lock)|package\\.json|yarn\\.lock) { deny all; }
"

  write_file "/etc/nginx/snippets/basic-antibot.conf" \
"if (\$bad_ua) { return 444; }

limit_conn ${ZONE_CONN} 20;
limit_req zone=perip burst=20 nodelay;

location = /xmlrpc.php { deny all; }

location = /wp-login.php {
  limit_req zone=login burst=5 nodelay;
  try_files \$uri \$uri/ /index.php?\$args;
}
"
}

write_default_site_conf() {
  mkdir -p "${DEFAULT_ROOT_BASE}/site/public"
  [[ -f "${DEFAULT_ROOT_BASE}/site/public/index.php" ]] || write_file "${DEFAULT_ROOT_BASE}/site/public/index.php" "<?php echo 'OK';"
  chown -R www-data:www-data "${DEFAULT_ROOT_BASE}/site"

  write_file "/etc/nginx/sites-available/site" \
"server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  root ${DEFAULT_ROOT_BASE}/site/public;
  index index.php index.html;

  include /etc/nginx/snippets/block-sensitive.conf;
  include /etc/nginx/snippets/basic-antibot.conf;

  location / { try_files \$uri \$uri/ /index.php?\$args; }

  location ~ \\.php\$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:/run/php/php8.3-fpm.sock;
  }

  location ~* \\.(jpg|jpeg|png|gif|css|js|ico|svg|woff2?)\$ {
    expires 7d;
    add_header Cache-Control \"public\";
  }
}
"
  rm -f /etc/nginx/sites-enabled/default || true
  ln -sf /etc/nginx/sites-available/site /etc/nginx/sites-enabled/site
  nginx -t
  systemctl reload nginx
}

ensure_logrotate_nginx() {
  write_file "/etc/logrotate.d/nginx-custom" \
"/var/log/nginx/*.log {
  daily
  rotate 14
  missingok
  notifempty
  compress
  delaycompress
  sharedscripts
  create 0640 www-data adm
  postrotate
    systemctl reload nginx > /dev/null 2>&1 || true
  endscript
}
"
}

install_update_cmd() {
  write_file "/usr/local/bin/webserver-update" \
"#!/usr/bin/env bash
set -euo pipefail
source /etc/webserver-installer.conf || true
if [[ -z \"\${INSTALL_URL:-}\" ]]; then
  echo \"INSTALL_URL is empty.\"
  echo \"Run once with:\"
  echo \"  curl -fsSL <raw>/webserver.sh | sudo INSTALL_URL='<raw>/webserver.sh' bash\"
  exit 1
fi
curl -fsSL \"\$INSTALL_URL\" | sudo INSTALL_URL=\"\$INSTALL_URL\" bash
echo \"Update done.\"
"
  chmod +x /usr/local/bin/webserver-update
}

install_dlh_menu() {
  cat >/usr/local/bin/dlh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/dlh-menu.conf"
ROOT_BASE_DEFAULT="/home/www"
PHP_SOCK="/run/php/php8.3-fpm.sock"

DLH_KEEP_BACKUPS="${DLH_KEEP_BACKUPS:-3}"
DLH_BACKUP_DIR="${DLH_BACKUP_DIR:-/var/backups/dlh}"
DLH_MANIFEST="${DLH_MANIFEST:-/var/lib/dlh/manifest.json}"
DLH_SECRETS_DIR="${DLH_SECRETS_DIR:-/var/lib/dlh/secrets}"
DLH_RCLONE_REMOTE="${DLH_RCLONE_REMOTE:-gdrive}"
DLH_GDRIVE_PATH="${DLH_GDRIVE_PATH:-DLH-Script/Backups}"

# Store one-time SSL email here
SSL_EMAIL_DEFAULT="${SSL_EMAIL_DEFAULT:-}"

# Optional MySQL admin creds storage (for dropping DB)
MYSQL_ADMIN_CNF="${MYSQL_ADMIN_CNF:-/var/lib/dlh/secrets/mysql-admin.cnf}"

is_tty() { [[ -t 1 ]]; }
if is_tty; then
  C_RESET=$'\033[0m'
  C_BOLD=$'\033[1m'
  C_DIM=$'\033[2m'
  C_RED=$'\033[31m'
  C_GRN=$'\033[32m'
  C_YEL=$'\033[33m'
  C_BLU=$'\033[34m'
  C_CYA=$'\033[36m'
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
  printf "%sBộ công cụ webserver cơ bản (Nginx/PHP/SSL/WordPress) - menu kiểu HOCVPS%s\n" "$C_DIM" "$C_RESET"
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
    # shellcheck disable=SC1090
    source "$CONF" || true
  fi
  INSTALL_URL="${INSTALL_URL:-}"
  ROOT_BASE="${ROOT_BASE:-$ROOT_BASE_DEFAULT}"
  ZONE_CONN="${ZONE_CONN:-dlh_connperip}"
  SSL_EMAIL="${SSL_EMAIL:-$SSL_EMAIL_DEFAULT}"
}

save_conf() {
  cat >"$CONF" <<EOF
INSTALL_URL="${INSTALL_URL}"
ROOT_BASE="${ROOT_BASE}"
ZONE_CONN="${ZONE_CONN}"
SSL_EMAIL="${SSL_EMAIL}"
MYSQL_ADMIN_CNF="${MYSQL_ADMIN_CNF}"
EOF
}

nginx_reload() { nginx -t && systemctl reload nginx; }

ensure_snippets() {
  mkdir -p /etc/nginx/snippets
  [[ -f /etc/nginx/snippets/block-sensitive.conf ]] || cat >/etc/nginx/snippets/block-sensitive.conf <<'EOF'
location ~* /\.((?!well-known).)* { deny all; }
location ~* /(\.git|\.svn|\.hg|\.env) { deny all; }
location ~* /(composer\.(json|lock)|package\.json|yarn\.lock) { deny all; }
EOF

  [[ -f /etc/nginx/snippets/basic-antibot.conf ]] || cat >/etc/nginx/snippets/basic-antibot.conf <<EOF
limit_conn ${ZONE_CONN} 20;
location = /xmlrpc.php { deny all; }
location = /wp-login.php { try_files \$uri \$uri/ /index.php?\$args; }
EOF
}

# ---------- MySQL helpers (for drop DB) ----------
mysql_try_socket_() {
  mysql -e "SELECT 1" >/dev/null 2>&1
}

mysql_try_admin_cnf_() {
  [[ -f "$MYSQL_ADMIN_CNF" ]] || return 1
  mysql --defaults-extra-file="$MYSQL_ADMIN_CNF" -e "SELECT 1" >/dev/null 2>&1
}

mysql_ensure_admin_() {
  mkdir -p "$(dirname "$MYSQL_ADMIN_CNF")"
  chmod 700 "$(dirname "$MYSQL_ADMIN_CNF")" 2>/dev/null || true

  if mysql_try_socket_; then
    return 0
  fi
  if mysql_try_admin_cnf_; then
    return 0
  fi

  msg_warn "Chưa có quyền MySQL để thao tác database."
  msg_warn "Nhập user/pass MySQL admin (thường là root). Thông tin sẽ lưu vào ${MYSQL_ADMIN_CNF}."
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

  if mysql_try_admin_cnf_; then
    msg_ok "Đã lưu MySQL admin creds."
    return 0
  fi

  rm -f "$MYSQL_ADMIN_CNF" || true
  msg_err "Sai user/password MySQL. Không thể thao tác database."
  return 1
}

mysql_exec_() {
  local sql="$1"
  if mysql_try_socket_; then
    mysql -e "$sql"
    return 0
  fi
  mysql_ensure_admin_ || return 1
  mysql --defaults-extra-file="$MYSQL_ADMIN_CNF" -e "$sql"
}

# ---------- Actions ----------
add_domain() {
  ensure_snippets
  local domain
  domain="$(read_tty "Nhập tên miền (vd: example.com): ")"
  domain="${domain,,}"
  [[ -n "$domain" ]] || { msg_err "Tên miền trống."; return; }

  local webroot="${ROOT_BASE}/${domain}/public"
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

  include /etc/nginx/snippets/block-sensitive.conf;
  include /etc/nginx/snippets/basic-antibot.conf;

  location / { try_files \$uri \$uri/ /index.php?\$args; }

  location ~ \\.php\$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:${PHP_SOCK};
  }
}
EOF

  ln -sf "$conf" "/etc/nginx/sites-enabled/${domain}.conf"
  nginx_reload
  msg_ok "Đã tạo website cho: ${domain}"
  msg_ok "Thư mục web: ${webroot}"
}

set_ssl_email() {
  local e
  e="$(read_tty "Nhập email mặc định (dùng cho SSL Let's Encrypt): ")"
  [[ -n "$e" ]] || { msg_err "Email trống."; return; }
  SSL_EMAIL="$e"
  save_conf
  msg_ok "Đã lưu email SSL mặc định: $SSL_EMAIL"
}

install_ssl() {
  local domain email
  domain="$(read_tty "Nhập tên miền để cài SSL (vd: example.com): ")"
  domain="${domain,,}"
  [[ -n "$domain" ]] || { msg_err "Tên miền trống."; return; }

  # email: use stored default; if empty -> ask once and save
  if [[ -n "${SSL_EMAIL:-}" ]]; then
    email="$SSL_EMAIL"
    msg_ok "Dùng email SSL mặc định: ${email}"
  else
    email="$(read_tty "Nhập email nhận thông báo SSL (lưu lại lần sau): ")"
    [[ -n "$email" ]] || { msg_err "Email trống."; return; }
    SSL_EMAIL="$email"
    save_conf
    msg_ok "Đã lưu email SSL mặc định."
  fi

  apt-get update -y
  apt-get install -y certbot python3-certbot-nginx

  local args=(-d "$domain")
  if getent ahosts "www.${domain}" >/dev/null 2>&1; then
    args+=(-d "www.${domain}")
    msg_ok "DNS có www.${domain} -> sẽ xin SSL kèm www"
  else
    msg_warn "DNS thiếu www.${domain} (NXDOMAIN) -> bỏ www, chỉ xin SSL cho ${domain}"
  fi

  if ! certbot --nginx "${args[@]}" \
    --cert-name "$domain" \
    --expand \
    -m "$email" --agree-tos --non-interactive --redirect; then
    msg_warn "Cài SSL thất bại. Kiểm tra DNS/Cloudflare và đảm bảo port 80 truy cập được."
    return
  fi

  systemctl enable --now certbot.timer || true

  sed -i 's/listen 443 ssl;/listen 443 ssl http2;/' /etc/nginx/sites-enabled/*.conf 2>/dev/null || true
  sed -i 's/listen \[::\]:443 ssl;/listen [::]:443 ssl http2;/' /etc/nginx/sites-enabled/*.conf 2>/dev/null || true

  nginx_reload
  msg_ok "Đã cài SSL thành công: https://${domain}"
}

delete_domain() {
  local domain
  domain="$(read_tty "Nhập tên miền cần XÓA (vd: example.com): ")"
  domain="${domain,,}"
  [[ -n "$domain" ]] || { msg_err "Tên miền trống."; return; }

  msg_warn "Sẽ xóa:"
  echo " - Nginx vhost: /etc/nginx/sites-available/${domain}.conf và sites-enabled/${domain}.conf"
  echo " - Thư mục web: ${ROOT_BASE}/${domain}"
  echo " - (Tuỳ chọn) SSL cert"
  echo " - (Tuỳ chọn) Database"
  local ans
  ans="$(read_tty "Xác nhận xóa ${domain}? (gõ YES để tiếp tục): ")"
  [[ "$ans" == "YES" ]] || { msg_warn "Hủy thao tác."; return; }

  rm -f "/etc/nginx/sites-enabled/${domain}.conf" 2>/dev/null || true
  rm -f "/etc/nginx/sites-available/${domain}.conf" 2>/dev/null || true
  rm -rf "${ROOT_BASE}/${domain}" 2>/dev/null || true

  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx || true
  else
    msg_warn "Nginx test fail sau khi xóa vhost. Chạy: nginx -t để kiểm tra."
  fi

  ans="$(read_tty "Xóa SSL certificate của ${domain}? (y/N): ")"
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    if command -v certbot >/dev/null 2>&1; then
      certbot delete --cert-name "$domain" --non-interactive >/dev/null 2>&1 || true
      msg_ok "Đã xóa cert (nếu có): $domain"
    else
      msg_warn "Chưa cài certbot."
    fi
  fi

  ans="$(read_tty "Xóa DATABASE? (y/N): ")"
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    local db
    db="$(read_tty "Nhập tên database cần xóa (vd: wp_example): ")"
    [[ -n "$db" ]] || { msg_warn "DB trống -> bỏ qua."; }
    if [[ -n "$db" ]]; then
      if mysql_exec_ "DROP DATABASE IF EXISTS \`${db}\`;" >/dev/null 2>&1; then
        msg_ok "Đã xóa database: $db"
      else
        msg_err "Không xóa được database. Kiểm tra MySQL creds."
      fi
    fi
  fi

  msg_ok "Đã xóa domain: $domain"
}

install_wpcli() {
  if command -v wp >/dev/null 2>&1; then
    msg_ok "WP-CLI đã có sẵn: $(wp --version)"
    return
  fi
  apt-get update -y
  apt-get install -y curl php-cli
  curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /tmp/wp-cli.phar
  php /tmp/wp-cli.phar --info >/dev/null
  chmod +x /tmp/wp-cli.phar
  mv /tmp/wp-cli.phar /usr/local/bin/wp
  msg_ok "Đã cài WP-CLI: $(wp --version)"
}

wp_download() {
  local domain dir cache
  domain="$(read_tty "Nhập tên miền (phải tồn tại trong ${ROOT_BASE}/<domain>/public): ")"
  domain="${domain,,}"
  dir="${ROOT_BASE}/${domain}/public"
  [[ -d "$dir" ]] || { msg_err "Không thấy thư mục web: $dir (hãy tạo Domain trước)."; return; }

  install_wpcli

  cache="${ROOT_BASE}/.wp-cli/cache"
  mkdir -p "$cache"
  mkdir -p "${ROOT_BASE}/.wp-cli"
  chown -R www-data:www-data "${ROOT_BASE}/.wp-cli"

  if [[ -f "${dir}/wp-config.php" || -d "${dir}/wp-admin" ]]; then
    msg_warn "WordPress có vẻ đã tồn tại tại $dir (bỏ qua)."
    return
  fi

  rm -f "${dir}/index.php" 2>/dev/null || true
  chown -R www-data:www-data "$dir"

  sudo -u www-data \
    WP_CLI_CACHE_DIR="$cache" \
    wp core download --path="$dir" --locale=vi --skip-content

  msg_ok "Đã tải WordPress (tiếng Việt) vào: $dir"
}

wp_fixperm() {
  local domain dir
  domain="$(read_tty "Nhập tên miền: ")"
  domain="${domain,,}"
  dir="${ROOT_BASE}/${domain}"
  [[ -d "$dir" ]] || { msg_err "Không tìm thấy: $dir"; return; }

  chown -R www-data:www-data "$dir"
  find "$dir" -type d -exec chmod 755 {} \;
  find "$dir" -type f -exec chmod 644 {} \;
  msg_ok "Đã sửa quyền (www-data) cho: $dir"
}

wp_menu() {
  while true; do
    banner
    printf "%s%s[TIỆN ÍCH WORDPRESS]%s\n" "$C_BOLD" "$C_BLU" "$C_RESET"
    echo "1) Cài WP-CLI"
    echo "2) Tải WordPress (tiếng Việt) vào thư mục domain"
    echo "3) Sửa quyền file/thư mục (www-data)"
    echo "0) Quay lại"
    hr
    case "$(read_tty "Chọn: ")" in
      1) install_wpcli; pause ;;
      2) wp_download; pause ;;
      3) wp_fixperm; pause ;;
      0) return ;;
      *) msg_warn "Lựa chọn không hợp lệ."; pause ;;
    esac
  done
}

# Backup menu kept (V2 stub/feature set already in your build)
ensure_tools_backup_() { apt-get update -y && apt-get install -y tar gzip coreutils findutils jq mariadb-client >/dev/null 2>&1 || true; }
ensure_rclone_() { command -v rclone >/dev/null 2>&1 && return 0; apt-get update -y; apt-get install -y rclone >/dev/null 2>&1 || return 1; }
rclone_remote_ready_() { command -v rclone >/dev/null 2>&1 || return 1; rclone listremotes 2>/dev/null | grep -qx "${DLH_RCLONE_REMOTE}:"; }
gdrive_setup_() { ensure_rclone_ || { msg_err "Không cài được rclone."; return 1; } ; msg_warn "Máy VPS là headless. Làm theo rclone config để lấy token."; rclone config; }

manifest_exists_() { [[ -f "$DLH_MANIFEST" ]] && [[ -s "$DLH_MANIFEST" ]]; }
list_domains_from_manifest_() { jq -r '.sites[]?.domain // empty' "$DLH_MANIFEST" 2>/dev/null; }
get_site_json_() { local domain="$1"; jq -c --arg d "$domain" '.sites[]? | select(.domain==$d)' "$DLH_MANIFEST" 2>/dev/null || true; }
safe_domain_() { local d="$1"; echo "$d" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9\.\-]//g'; }
backup_prune_local_() { local domain="$1" keep="${2:-$DLH_KEEP_BACKUPS}" d base to_delete; d="$(safe_domain_ "$domain")"; base="${DLH_BACKUP_DIR}/${d}"; [[ -d "$base" ]] || return 0; to_delete="$(ls -1dt "${base}/"*/ 2>/dev/null | tail -n +"$((keep+1))" || true)"; [[ -n "$to_delete" ]] && echo "$to_delete" | while IFS= read -r p; do rm -rf "$p" || true; done; }
backup_site_local_() { msg_warn "Chức năng backup local yêu cầu manifest V2 (tên miền/webroot/db)."; }
backup_all_local_() { msg_warn "Chức năng backup local ALL yêu cầu manifest V2."; }
gdrive_upload_domain_() { msg_warn "Upload GDrive yêu cầu backup local + rclone remote."; }
gdrive_upload_all_() { msg_warn "Upload GDrive ALL yêu cầu backup local + rclone remote."; }
backup_prune_all_() { msg_warn "Dọn backup yêu cầu backup local."; }

menu_backup() {
  while true; do
    banner
    printf "%s%s[SAO LƯU / BACKUP]%s\n" "$C_BOLD" "$C_BLU" "$C_RESET"
    echo "1) Sao lưu 1 website theo tên miền (Local) [V2]"
    echo "2) Sao lưu TẤT CẢ website (Local) [V2]"
    echo "3) Upload backup 1 tên miền lên Google Drive [V2]"
    echo "4) Upload backup TẤT CẢ lên Google Drive [V2]"
    echo "5) Kết nối Google Drive (rclone config)"
    echo "6) Dọn backup local (giữ ${DLH_KEEP_BACKUPS} bản/domain) [V2]"
    echo "0) Quay lại"
    hr
    case "$(read_tty "Chọn: ")" in
      1) backup_site_local_ "x"; pause ;;
      2) backup_all_local_; pause ;;
      3) gdrive_upload_domain_ "x"; pause ;;
      4) gdrive_upload_all_; pause ;;
      5) gdrive_setup_; pause ;;
      6) backup_prune_all_; pause ;;
      0) return ;;
      *) msg_warn "Lựa chọn không hợp lệ."; pause ;;
    esac
  done
}

nginx_tools() {
  banner
  echo "${C_BOLD}Kiểm tra cấu hình Nginx (nginx -t)${C_RESET}"
  nginx -t || true
  echo
  echo "${C_BOLD}Trạng thái dịch vụ (nginx/php-fpm)${C_RESET}"
  systemctl status nginx php8.3-fpm --no-pager || true
  hr
  pause
}

set_update_url() {
  local url
  url="$(read_tty "Nhập RAW URL của webserver.sh trên GitHub: ")"
  INSTALL_URL="$url"
  save_conf
  msg_ok "Đã lưu INSTALL_URL."
}

run_update() {
  if command -v webserver-update >/dev/null 2>&1; then
    webserver-update
    msg_ok "Đã cập nhật bằng webserver-update."
    return
  fi
  if [[ -z "${INSTALL_URL}" ]]; then
    msg_err "INSTALL_URL đang trống. Hãy đặt URL trước."
    return
  fi
  curl -fsSL "$INSTALL_URL" | sudo INSTALL_URL="$INSTALL_URL" bash
  msg_ok "Đã cập nhật từ: $INSTALL_URL"
}

set_root_base() {
  local v
  v="$(read_tty "Thư mục web gốc ROOT_BASE (hiện tại: ${ROOT_BASE}): ")"
  [[ -n "$v" ]] && ROOT_BASE="$v"
  save_conf
  msg_ok "ROOT_BASE=${ROOT_BASE}"
}

menu_domain_ssl() {
  while true; do
    banner
    printf "%s%s[TÊN MIỀN / SSL]%s\n" "$C_BOLD" "$C_BLU" "$C_RESET"
    echo "1) Thêm tên miền (tạo vhost Nginx + thư mục web)"
    echo "2) Cài SSL miễn phí (Let's Encrypt + HTTP/2 + tự gia hạn)"
    echo "3) Xóa tên miền (vhost + thư mục web + tuỳ chọn SSL/DB)"
    echo "4) Thiết lập email SSL mặc định (lưu 1 lần)"
    echo "0) Quay lại"
    hr
    case "$(read_tty "Chọn: ")" in
      1) add_domain; pause ;;
      2) install_ssl; pause ;;
      3) delete_domain; pause ;;
      4) set_ssl_email; pause ;;
      0) return ;;
      *) msg_warn "Lựa chọn không hợp lệ."; pause ;;
    esac
  done
}

menu_system() {
  while true; do
    banner
    printf "%s%s[HỆ THỐNG / CÔNG CỤ]%s\n" "$C_BOLD" "$C_BLU" "$C_RESET"
    echo "1) Công cụ Nginx (test/status)"
    echo "2) Cập nhật script từ GitHub"
    echo "3) Thiết lập URL cập nhật (INSTALL_URL)"
    echo "4) Thiết lập thư mục web gốc (ROOT_BASE)"
    echo "0) Quay lại"
    hr
    case "$(read_tty "Chọn: ")" in
      1) nginx_tools ;;
      2) run_update; pause ;;
      3) set_update_url; pause ;;
      4) set_root_base; pause ;;
      0) return ;;
      *) msg_warn "Lựa chọn không hợp lệ."; pause ;;
    esac
  done
}

main_menu() {
  while true; do
    banner
    echo "1) Tên miền / SSL"
    echo "2) Tiện ích WordPress"
    echo "3) Sao lưu / Backup"
    echo "4) Hệ thống / Công cụ"
    echo "0) Thoát"
    hr
    case "$(read_tty "Chọn: ")" in
      1) menu_domain_ssl ;;
      2) wp_menu ;;
      3) menu_backup ;;
      4) menu_system ;;
      0) exit 0 ;;
      *) msg_warn "Lựa chọn không hợp lệ."; pause ;;
    esac
  done
}

load_conf
main_menu
SH
  chmod +x /usr/local/bin/dlh
}

main() {
  need_root
  save_conf

  echo "[1/6] UFW + Fail2ban + Swap"
  apt_install software-properties-common
  ensure_ufw
  ensure_fail2ban
  ensure_swap_2g

  echo "[2/6] Nginx + PHP"
  ensure_nginx_php

  echo "[3/6] Nginx global configs"
  write_nginx_global_conf

  echo "[4/6] Default site (no domain)"
  write_default_site_conf

  echo "[5/6] Logrotate"
  ensure_logrotate_nginx

  echo "[6/6] Menu + updater"
  install_dlh_menu
  install_update_cmd

  echo "DONE ✅"
  echo "- Run menu: dlh"
  echo "- Update later: sudo webserver-update"
  echo "- Default ROOT_BASE: ${DEFAULT_ROOT_BASE}"
}

main
