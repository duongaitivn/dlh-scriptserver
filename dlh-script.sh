#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# DLH-Script V2 — Menu
# Command: dlh
# =========================================================

CONF="/etc/dlh-menu.conf"
ROOT_BASE_DEFAULT="/home/www"
PHP_SOCK="/run/php/php8.3-fpm.sock"
ZONE_CONN_DEFAULT="dlh_connperip"
MANIFEST="/var/lib/dlh/manifest.json"
MYSQL_ADMIN_CNF_DEFAULT="/var/lib/dlh/secrets/mysql-admin.cnf"

BACKUP_DIR_DEFAULT="/var/backups/dlh"
KEEP_BACKUPS_DEFAULT="3"
RCLONE_REMOTE_DEFAULT="gdrive"
RCLONE_PATH_DEFAULT="DLH-Script/Backups"

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
  printf "%s%sDLH-Script V2%s\n" "$C_BOLD" "$C_CYA" "$C_RESET"
  printf "%sMenu quản trị webserver cơ bản (nginx/php/ssl/wp/backup)%s\n" "$C_DIM" "$C_RESET"
  hr
}
msg_ok()   { printf "%s[OK]%s %s\n"   "$C_GRN" "$C_RESET" "$*"; }
msg_warn() { printf "%s[CẢNH BÁO]%s %s\n" "$C_YEL" "$C_RESET" "$*"; }
msg_err()  { printf "%s[LỖI]%s %s\n"  "$C_RED" "$C_RESET" "$*"; }

if [[ "${EUID}" -ne 0 ]]; then
  exec sudo -E "$0" "$@"
fi

ensure_dirs_() {
  mkdir -p /var/lib/dlh/secrets /var/lib/dlh
  chmod 700 /var/lib/dlh/secrets || true
  if [[ ! -f "$MANIFEST" ]]; then
    printf '{"sites":[]}\n' > "$MANIFEST"
  fi
}

need_jq_() {
  command -v jq >/dev/null 2>&1 || apt_install_ jq
}

load_conf() {
  if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF" || true
  fi
  ROOT_BASE="${ROOT_BASE:-$ROOT_BASE_DEFAULT}"
  ZONE_CONN="${ZONE_CONN:-$ZONE_CONN_DEFAULT}"
  SSL_EMAIL="${SSL_EMAIL:-}"
  MYSQL_ADMIN_CNF="${MYSQL_ADMIN_CNF:-$MYSQL_ADMIN_CNF_DEFAULT}"
  BACKUP_DIR="${BACKUP_DIR:-$BACKUP_DIR_DEFAULT}"
  KEEP_BACKUPS="${KEEP_BACKUPS:-$KEEP_BACKUPS_DEFAULT}"
  RCLONE_REMOTE="${RCLONE_REMOTE:-$RCLONE_REMOTE_DEFAULT}"
  RCLONE_PATH="${RCLONE_PATH:-$RCLONE_PATH_DEFAULT}"
}

save_conf() {
  mkdir -p "$(dirname "$CONF")"
  cat >"$CONF" <<EOF
ROOT_BASE="${ROOT_BASE}"
ZONE_CONN="${ZONE_CONN}"
SSL_EMAIL="${SSL_EMAIL}"
MYSQL_ADMIN_CNF="${MYSQL_ADMIN_CNF}"
BACKUP_DIR="${BACKUP_DIR}"
KEEP_BACKUPS="${KEEP_BACKUPS}"
RCLONE_REMOTE="${RCLONE_REMOTE}"
RCLONE_PATH="${RCLONE_PATH}"
EOF
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
limit_req zone=perip burst=20 nodelay;
location = /xmlrpc.php { deny all; }
location = /wp-login.php { limit_req zone=login burst=5 nodelay; try_files \$uri \$uri/ /index.php?\$args; }
EOF
}

nginx_reload() { nginx -t && systemctl reload nginx; }

# ---------- Manifest helpers ----------
manifest_has_() { [[ -f "$MANIFEST" ]] && [[ -s "$MANIFEST" ]]; }

site_exists_() {
  local domain="$1"
  need_jq_
  jq -e --arg d "$domain" '.sites[]? | select(.domain==$d)' "$MANIFEST" >/dev/null 2>&1
}

manifest_upsert_site_() {
  local domain="$1" webroot="$2"
  need_jq_
  local now
  now="$(date -Is)"
  tmp="$(mktemp)"
  jq --arg d "$domain" --arg w "$webroot" --arg t "$now" '
    .sites = (
      (.sites // []) | map(select(.domain != $d))
      + [{
          "domain": $d,
          "webroot": $w,
          "db_name": (.sites[]? | select(.domain==$d) | .db_name) // "",
          "db_user": (.sites[]? | select(.domain==$d) | .db_user) // "",
          "ssl": (.sites[]? | select(.domain==$d) | .ssl) // false,
          "created_at": (.sites[]? | select(.domain==$d) | .created_at) // $t,
          "updated_at": $t
        }]
    )
  ' "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"
}

manifest_set_ssl_() {
  local domain="$1" val="$2"
  need_jq_
  tmp="$(mktemp)"
  jq --arg d "$domain" --argjson v "$val" --arg t "$(date -Is)" '
    .sites = (.sites | map(if .domain==$d then .ssl=$v | .updated_at=$t else . end))
  ' "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"
}

manifest_remove_site_() {
  local domain="$1"
  need_jq_
  tmp="$(mktemp)"
  jq --arg d "$domain" '
    .sites = (.sites | map(select(.domain != $d)))
  ' "$MANIFEST" > "$tmp"
  mv "$tmp" "$MANIFEST"
}

manifest_get_() {
  local domain="$1" key="$2"
  need_jq_
  jq -r --arg d "$domain" --arg k "$key" '
    (.sites[]? | select(.domain==$d) | .[$k]) // ""
  ' "$MANIFEST"
}

list_domains_() {
  need_jq_
  jq -r '.sites[]?.domain // empty' "$MANIFEST"
}

# ---------- MySQL helpers ----------
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
  if mysql_try_socket_; then mysql -e "$sql"; return 0; fi
  mysql_ensure_admin_ || return 1
  mysql --defaults-extra-file="$MYSQL_ADMIN_CNF" -e "$sql"
}

# ---------- WordPress / DB autodetect ----------
detect_wp_db_() {
  local webroot="$1"
  local cfg="${webroot}/wp-config.php"
  [[ -f "$cfg" ]] || return 1
  local db user
  db="$(php -r '$c=file_get_contents("'"$cfg"'"); if(preg_match("/define\\(\\s*\\x27DB_NAME\\x27\\s*,\\s*\\x27([^\\x27]+)\\x27\\s*\\)/",$c,$m)) echo $m[1];' 2>/dev/null || true)"
  user="$(php -r '$c=file_get_contents("'"$cfg"'"); if(preg_match("/define\\(\\s*\\x27DB_USER\\x27\\s*,\\s*\\x27([^\\x27]+)\\x27\\s*\\)/",$c,$m)) echo $m[1];' 2>/dev/null || true)"
  [[ -n "$db" ]] || return 1
  echo "$db|$user"
}

# ---------- Actions ----------
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

  include /etc/nginx/snippets/dlh-block-sensitive.conf;
  include /etc/nginx/snippets/dlh-basic-antibot.conf;

  location / { try_files \$uri \$uri/ /index.php?\$args; }

  location ~ \\.php$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:${PHP_SOCK};
  }
}
EOF

  ln -sf "$conf" "/etc/nginx/sites-enabled/${domain}.conf"
  nginx_reload

  manifest_upsert_site_ "$domain" "$webroot"
  msg_ok "Đã tạo website: ${domain}"
  msg_ok "Webroot: ${webroot}"
}

install_ssl() {
  local domain email
  domain="$(read_tty "Nhập tên miền để cài SSL (vd: example.com): ")"
  domain="${domain,,}"
  [[ -n "$domain" ]] || { msg_err "Tên miền trống."; return; }

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

  apt_install_ certbot python3-certbot-nginx

  local args=(-d "$domain")
  if getent ahosts "www.${domain}" >/dev/null 2>&1; then
    args+=(-d "www.${domain}")
    msg_ok "DNS có www.${domain} -> xin SSL kèm www"
  else
    msg_warn "DNS thiếu www.${domain} -> bỏ www"
  fi

  if ! certbot --nginx "${args[@]}" --cert-name "$domain" --expand \
    -m "$email" --agree-tos --non-interactive --redirect; then
    msg_warn "Cài SSL thất bại. Kiểm tra DNS/Cloudflare và đảm bảo port 80 truy cập được."
    return
  fi

  systemctl enable --now certbot.timer || true
  sed -i 's/listen 443 ssl;/listen 443 ssl http2;/' /etc/nginx/sites-enabled/*.conf 2>/dev/null || true
  sed -i 's/listen \[::\]:443 ssl;/listen [::]:443 ssl http2;/' /etc/nginx/sites-enabled/*.conf 2>/dev/null || true
  nginx_reload

  manifest_set_ssl_ "$domain" "true" || true
  msg_ok "SSL OK: https://${domain}"
}

delete_domain() {
  local domain ans webroot dbinfo db dbuser
  domain="$(read_tty "Nhập tên miền cần XÓA (vd: example.com): ")"
  domain="${domain,,}"
  [[ -n "$domain" ]] || { msg_err "Tên miền trống."; return; }

  msg_warn "Sẽ xóa vhost + webroot (tuỳ chọn SSL/DB)."
  ans="$(read_tty "Xác nhận xóa ${domain}? (gõ YES để tiếp tục): ")"
  [[ "$ans" == "YES" ]] || { msg_warn "Hủy."; return; }

  rm -f "/etc/nginx/sites-enabled/${domain}.conf" 2>/dev/null || true
  rm -f "/etc/nginx/sites-available/${domain}.conf" 2>/dev/null || true

  webroot="$(manifest_get_ "$domain" "webroot" 2>/dev/null || true)"
  [[ -n "$webroot" ]] || webroot="${ROOT_BASE}/${domain}/public"
  rm -rf "${ROOT_BASE}/${domain}" 2>/dev/null || true

  nginx -t >/dev/null 2>&1 && systemctl reload nginx || true

  ans="$(read_tty "Xóa SSL certificate của ${domain}? (y/N): ")"
  if [[ "$ans" =~ ^[Yy]$ ]] && command -v certbot >/dev/null 2>&1; then
    certbot delete --cert-name "$domain" --non-interactive >/dev/null 2>&1 || true
    msg_ok "Đã xóa cert (nếu có)."
  fi

  # Try autodetect DB from wp-config before deletion (if webroot exists in backup, likely gone already)
  db="$(manifest_get_ "$domain" "db_name" 2>/dev/null || true)"
  dbuser="$(manifest_get_ "$domain" "db_user" 2>/dev/null || true)"
  if [[ -z "$db" && -n "$webroot" && -f "${webroot}/wp-config.php" ]]; then
    dbinfo="$(detect_wp_db_ "$webroot" || true)"
    db="${dbinfo%%|*}"
    dbuser="${dbinfo##*|}"
  fi

  ans="$(read_tty "Xóa DATABASE? (y/N): ")"
  if [[ "$ans" =~ ^[Yy]$ ]]; then
    if [[ -z "$db" ]]; then
      db="$(read_tty "Nhập tên database cần xóa: ")"
    else
      msg_ok "Phát hiện DB: ${db}"
      ans2="$(read_tty "Xóa DB này? (y/N): ")"
      [[ "$ans2" =~ ^[Yy]$ ]] || db=""
    fi
    if [[ -n "$db" ]]; then
      mysql_exec_ "DROP DATABASE IF EXISTS \`${db}\`;" >/dev/null 2>&1 \
        && msg_ok "Đã xóa DB: $db" \
        || msg_err "Không xóa được DB. Kiểm tra MySQL creds."
    fi
  fi

  manifest_remove_site_ "$domain" || true
  msg_ok "Đã xóa domain: $domain"
}

list_domains() {
  ensure_dirs_
  if ! manifest_has_; then
    msg_warn "Chưa có manifest."
    return
  fi
  echo "Danh sách domain:"
  list_domains_ | sed '/^$/d' | nl -w2 -s') ' || true
}

# ---------- WP utilities ----------
install_wpcli() {
  if command -v wp >/dev/null 2>&1; then
    msg_ok "WP-CLI đã có: $(wp --version)"
    return
  fi
  apt_install_ curl php-cli
  curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /tmp/wp-cli.phar
  php /tmp/wp-cli.phar --info >/dev/null
  chmod +x /tmp/wp-cli.phar
  mv /tmp/wp-cli.phar /usr/local/bin/wp
  msg_ok "Đã cài WP-CLI: $(wp --version)"
}

wp_download() {
  local domain webroot cache
  domain="$(read_tty "Nhập tên miền (đã tạo): ")"
  domain="${domain,,}"
  webroot="$(manifest_get_ "$domain" "webroot" 2>/dev/null || true)"
  [[ -n "$webroot" ]] || webroot="${ROOT_BASE}/${domain}/public"
  [[ -d "$webroot" ]] || { msg_err "Không thấy webroot: $webroot"; return; }

  install_wpcli

  cache="${ROOT_BASE}/.wp-cli/cache"
  mkdir -p "$cache" "${ROOT_BASE}/.wp-cli"
  chown -R www-data:www-data "${ROOT_BASE}/.wp-cli"

  if [[ -f "${webroot}/wp-config.php" || -d "${webroot}/wp-admin" ]]; then
    msg_warn "WordPress có vẻ đã tồn tại tại $webroot (bỏ qua)."
    return
  fi

  rm -f "${webroot}/index.php" 2>/dev/null || true
  chown -R www-data:www-data "$webroot"

  sudo -u www-data WP_CLI_CACHE_DIR="$cache" wp core download --path="$webroot" --locale=vi --skip-content
  msg_ok "Đã tải WordPress vào: $webroot"
}

wp_fixperm() {
  local domain base
  domain="$(read_tty "Nhập tên miền: ")"
  domain="${domain,,}"
  base="${ROOT_BASE}/${domain}"
  [[ -d "$base" ]] || { msg_err "Không tìm thấy: $base"; return; }
  chown -R www-data:www-data "$base"
  find "$base" -type d -exec chmod 755 {} \;
  find "$base" -type f -exec chmod 644 {} \;
  msg_ok "Đã sửa quyền (www-data) cho: $base"
}

wp_menu() {
  while true; do
    banner
    printf "%s%s[WORDPRESS]%s\n" "$C_BOLD" "$C_BLU" "$C_RESET"
    echo "1) Cài WP-CLI"
    echo "2) Tải WordPress (tiếng Việt) vào webroot"
    echo "3) Sửa quyền file/thư mục (www-data)"
    echo "0) Quay lại"
    hr
    case "$(read_tty "Chọn: ")" in
      1) install_wpcli; pause ;;
      2) wp_download; pause ;;
      3) wp_fixperm; pause ;;
      0) return ;;
      *) msg_warn "Sai lựa chọn."; pause ;;
    esac
  done
}

# ---------- Backup ----------
ensure_backup_tools_() {
  apt_install_ tar gzip coreutils findutils
  command -v mysqldump >/dev/null 2>&1 || apt_install_ mariadb-client
}

backup_prune_domain_() {
  local domain="$1" keep="$KEEP_BACKUPS"
  local base="${BACKUP_DIR}/${domain}"
  [[ -d "$base" ]] || return 0
  local del
  del="$(ls -1dt "${base}/"*/ 2>/dev/null | tail -n +"$((keep+1))" || true)"
  [[ -n "$del" ]] && echo "$del" | while IFS= read -r p; do rm -rf "$p" || true; done
}

backup_one_local() {
  ensure_backup_tools_
  local domain webroot ts outdir db dbuser dbinfo

  domain="$(read_tty "Nhập domain cần backup: ")"
  domain="${domain,,}"
  [[ -n "$domain" ]] || { msg_err "Domain trống."; return; }

  webroot="$(manifest_get_ "$domain" "webroot" 2>/dev/null || true)"
  [[ -n "$webroot" ]] || webroot="${ROOT_BASE}/${domain}/public"
  [[ -d "$webroot" ]] || { msg_err "Không thấy webroot: $webroot"; return; }

  ts="$(date +%Y%m%d_%H%M%S)"
  outdir="${BACKUP_DIR}/${domain}/${ts}"
  mkdir -p "$outdir"

  # Tar code
  tar -C "$webroot" -czf "${outdir}/code.tar.gz" .

  # DB (auto from manifest or wp-config)
  db="$(manifest_get_ "$domain" "db_name" 2>/dev/null || true)"
  dbuser="$(manifest_get_ "$domain" "db_user" 2>/dev/null || true)"
  if [[ -z "$db" ]]; then
    dbinfo="$(detect_wp_db_ "$webroot" || true)"
    db="${dbinfo%%|*}"
    dbuser="${dbinfo##*|}"
  fi

  if [[ -n "$db" ]]; then
    mysql_ensure_admin_ || { msg_warn "Không dump DB vì thiếu MySQL quyền."; }
    if [[ -f "$MYSQL_ADMIN_CNF" ]]; then
      mysqldump --defaults-extra-file="$MYSQL_ADMIN_CNF" --single-transaction --quick --routines --events "$db" \
        | gzip > "${outdir}/db.sql.gz" || msg_warn "Dump DB lỗi."
    else
      msg_warn "Không dump DB vì chưa có MySQL creds."
    fi
  else
    msg_warn "Không phát hiện DB (bỏ qua dump DB)."
  fi

  backup_prune_domain_ "$domain"
  msg_ok "Backup local xong: ${outdir}"
}

backup_all_local() {
  local d
  mapfile -t domains < <(list_domains_ 2>/dev/null || true)
  if [[ "${#domains[@]}" -eq 0 ]]; then
    msg_warn "Chưa có domain trong manifest."
    return
  fi
  for d in "${domains[@]}"; do
    echo
    msg_ok "Backup: $d"
    echo
    (echo "$d" | true) >/dev/null 2>&1 || true
    # call interactive function by temporarily reading domain from tty is messy; just call internal logic
    # replicate minimal without prompt:
    ensure_backup_tools_
    local webroot ts outdir db dbinfo
    webroot="$(manifest_get_ "$d" "webroot" 2>/dev/null || true)"
    [[ -n "$webroot" ]] || webroot="${ROOT_BASE}/${d}/public"
    [[ -d "$webroot" ]] || { msg_warn "Skip (missing webroot): $webroot"; continue; }
    ts="$(date +%Y%m%d_%H%M%S)"
    outdir="${BACKUP_DIR}/${d}/${ts}"
    mkdir -p "$outdir"
    tar -C "$webroot" -czf "${outdir}/code.tar.gz" .
    db="$(manifest_get_ "$d" "db_name" 2>/dev/null || true)"
    if [[ -z "$db" ]]; then
      dbinfo="$(detect_wp_db_ "$webroot" || true)"
      db="${dbinfo%%|*}"
    fi
    if [[ -n "$db" && -f "$MYSQL_ADMIN_CNF" ]]; then
      mysqldump --defaults-extra-file="$MYSQL_ADMIN_CNF" --single-transaction --quick --routines --events "$db" \
        | gzip > "${outdir}/db.sql.gz" || true
    fi
    backup_prune_domain_ "$d"
    msg_ok "OK: ${outdir}"
  done
}

ensure_rclone_() {
  command -v rclone >/dev/null 2>&1 || apt_install_ rclone
}

gdrive_setup() {
  ensure_rclone_
  msg_warn "Máy VPS thường không có trình duyệt. Bạn làm theo hướng dẫn rclone config để lấy token."
  echo "Chạy: rclone config"
  echo "Sau khi tạo remote, nó phải có tên: ${RCLONE_REMOTE}"
  rclone config
}

gdrive_upload_domain() {
  ensure_rclone_
  local domain base latest
  domain="$(read_tty "Nhập domain cần upload: ")"
  domain="${domain,,}"
  base="${BACKUP_DIR}/${domain}"
  [[ -d "$base" ]] || { msg_err "Chưa có backup local cho domain này."; return; }
  latest="$(ls -1dt "${base}/"*/ 2>/dev/null | head -n 1 || true)"
  [[ -n "$latest" ]] || { msg_err "Không tìm thấy bản backup."; return; }
  rclone copy "$latest" "${RCLONE_REMOTE}:${RCLONE_PATH}/${domain}/$(basename "$latest")" -P
  msg_ok "Upload xong: ${domain}"
}

gdrive_upload_all() {
  ensure_rclone_
  local d base
  mapfile -t domains < <(list_domains_ 2>/dev/null || true)
  [[ "${#domains[@]}" -gt 0 ]] || { msg_warn "Chưa có domain trong manifest."; return; }
  for d in "${domains[@]}"; do
    base="${BACKUP_DIR}/${d}"
    [[ -d "$base" ]] || continue
    local latest
    latest="$(ls -1dt "${base}/"*/ 2>/dev/null | head -n 1 || true)"
    [[ -n "$latest" ]] || continue
    rclone copy "$latest" "${RCLONE_REMOTE}:${RCLONE_PATH}/${d}/$(basename "$latest")" -P || true
  done
  msg_ok "Upload all xong."
}

backup_menu() {
  while true; do
    banner
    printf "%s%s[BACKUP]%s\n" "$C_BOLD" "$C_BLU" "$C_RESET"
    echo "1) Backup 1 domain (Local)"
    echo "2) Backup tất cả domain (Local)"
    echo "3) Kết nối Google Drive (rclone config)"
    echo "4) Upload backup domain mới nhất lên Google Drive"
    echo "5) Upload backup tất cả domain mới nhất lên Google Drive"
    echo "0) Quay lại"
    hr
    case "$(read_tty "Chọn: ")" in
      1) backup_one_local; pause ;;
      2) backup_all_local; pause ;;
      3) gdrive_setup; pause ;;
      4) gdrive_upload_domain; pause ;;
      5) gdrive_upload_all; pause ;;
      0) return ;;
      *) msg_warn "Sai lựa chọn."; pause ;;
    esac
  done
}

# ---------- Security/System ----------
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

view_logs() {
  local domain
  domain="$(read_tty "Nhập domain để xem log (enter để bỏ): ")"
  if [[ -n "$domain" ]]; then
    domain="${domain,,}"
    banner
    echo "tail -n 200 /var/log/nginx/${domain}.access.log"
    echo "tail -n 200 /var/log/nginx/${domain}.error.log"
    hr
    tail -n 200 "/var/log/nginx/${domain}.access.log" 2>/dev/null || true
    hr
    tail -n 200 "/var/log/nginx/${domain}.error.log" 2>/dev/null || true
    pause
  fi
}

set_root_base() {
  local v
  v="$(read_tty "ROOT_BASE (hiện tại: ${ROOT_BASE}): ")"
  [[ -n "$v" ]] && ROOT_BASE="$v"
  save_conf
  msg_ok "ROOT_BASE=${ROOT_BASE}"
}

set_backup_opts() {
  local v
  v="$(read_tty "BACKUP_DIR (hiện tại: ${BACKUP_DIR}): ")"
  [[ -n "$v" ]] && BACKUP_DIR="$v"
  v="$(read_tty "KEEP_BACKUPS (hiện tại: ${KEEP_BACKUPS}): ")"
  [[ -n "$v" ]] && KEEP_BACKUPS="$v"
  save_conf
  msg_ok "Đã lưu cấu hình backup."
}

set_rclone_opts() {
  local v
  v="$(read_tty "RCLONE_REMOTE (hiện tại: ${RCLONE_REMOTE}): ")"
  [[ -n "$v" ]] && RCLONE_REMOTE="$v"
  v="$(read_tty "RCLONE_PATH (hiện tại: ${RCLONE_PATH}): ")"
  [[ -n "$v" ]] && RCLONE_PATH="$v"
  save_conf
  msg_ok "Đã lưu cấu hình Google Drive."
}

run_update() {
  if command -v dlh-update >/dev/null 2>&1; then
    dlh-update
    msg_ok "Đã update."
  else
    msg_err "Chưa có dlh-update."
  fi
}

security_menu() {
  while true; do
    banner
    printf "%s%s[SECURITY]%s\n" "$C_BOLD" "$C_BLU" "$C_RESET"
    echo "1) UFW status"
    echo "2) Fail2ban status"
    echo "0) Quay lại"
    hr
    case "$(read_tty "Chọn: ")" in
      1) banner; ufw status verbose || true; pause ;;
      2) banner; fail2ban-client status || true; pause ;;
      0) return ;;
      *) msg_warn "Sai lựa chọn."; pause ;;
    esac
  done
}

system_menu() {
  while true; do
    banner
    printf "%s%s[SYSTEM]%s\n" "$C_BOLD" "$C_BLU" "$C_RESET"
    echo "1) Công cụ Nginx"
    echo "2) Xem log theo domain"
    echo "3) Update script từ GitHub"
    echo "4) Đổi ROOT_BASE"
    echo "5) Cấu hình backup"
    echo "6) Cấu hình Google Drive (rclone)"
    echo "0) Quay lại"
    hr
    case "$(read_tty "Chọn: ")" in
      1) nginx_tools ;;
      2) view_logs ;;
      3) run_update; pause ;;
      4) set_root_base; pause ;;
      5) set_backup_opts; pause ;;
      6) set_rclone_opts; pause ;;
      0) return ;;
      *) msg_warn "Sai lựa chọn."; pause ;;
    esac
  done
}

domain_ssl_menu() {
  while true; do
    banner
    printf "%s%s[DOMAIN / SSL]%s\n" "$C_BOLD" "$C_BLU" "$C_RESET"
    echo "1) Thêm domain"
    echo "2) Cài SSL"
    echo "3) Xóa domain"
    echo "4) Thiết lập email SSL mặc định"
    echo "5) Liệt kê domain"
    echo "0) Quay lại"
    hr
    case "$(read_tty "Chọn: ")" in
      1) add_domain; pause ;;
      2) install_ssl; pause ;;
      3) delete_domain; pause ;;
      4) set_ssl_email; pause ;;
      5) list_domains; pause ;;
      0) return ;;
      *) msg_warn "Sai lựa chọn."; pause ;;
    esac
  done
}

main_menu() {
  while true; do
    banner
    echo "1) Webserver / Domain / SSL"
    echo "2) WordPress"
    echo "3) Backup"
    echo "4) Security"
    echo "5) System"
    echo "0) Thoát"
    hr
    case "$(read_tty "Chọn: ")" in
      1) domain_ssl_menu ;;
      2) wp_menu ;;
      3) backup_menu ;;
      4) security_menu ;;
      5) system_menu ;;
      0) exit 0 ;;
      *) msg_warn "Sai lựa chọn."; pause ;;
    esac
  done
}

ensure_dirs_
load_conf
main_menu
