\
#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# DLH-Script V2 — install + update (idempotent)
# Files installed:
#  - /usr/local/bin/dlh        (menu runner)
#  - /usr/local/bin/dlh-update (self update)
# Root base (web): /home/www/<domain>/public_html
# =========================================================

DEFAULT_INSTALL_URL="https://raw.githubusercontent.com/duongaitivn/dlh-scriptserver/main/installandupdate.sh"
DEFAULT_MENU_URL="https://raw.githubusercontent.com/duongaitivn/dlh-scriptserver/main/dlh-script.sh"

CONF_DIR="/etc/dlh-script"
INSTALL_URL_FILE="${CONF_DIR}/install_url"
MENU_URL_FILE="${CONF_DIR}/menu_url"

force_ipv4_apt() {
  # Help fix "Waiting for headers" on some VPS/IPv6 issues
  mkdir -p /etc/apt/apt.conf.d
  cat >/etc/apt/apt.conf.d/99force-ipv4 <<'EOF'
Acquire::ForceIPv4 "true";
EOF
}

apt_update_install() {
  export DEBIAN_FRONTEND=noninteractive
  force_ipv4_apt
  apt-get update -y
  apt-get install -y curl ca-certificates gnupg lsb-release \
    nginx \
    php-fpm php-cli php-mysql php-curl php-mbstring php-xml php-zip php-gd php-intl \
    certbot python3-certbot-nginx \
    ufw fail2ban logrotate \
    unzip tar gzip \
    dnsutils
}

ensure_dirs() {
  mkdir -p "${CONF_DIR}"
  mkdir -p /home/www
  mkdir -p /etc/nginx/snippets
  mkdir -p /etc/nginx/conf.d
}

write_file_once() {
  local path="$1"; shift
  local content="$1"
  if [[ -f "$path" ]]; then
    return 0
  fi
  printf "%s" "$content" >"$path"
}

write_nginx_global() {
  # 00-dlh-security.conf (do NOT duplicate server_tokens)
  cat >/etc/nginx/conf.d/00-dlh-security.conf <<'EOF'
server_tokens off;

# Basic hardening
client_max_body_size 256m;
keepalive_timeout 65;

# gzip (safe defaults)
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_types
  text/plain text/css text/xml
  text/javascript application/javascript application/x-javascript
  application/json application/xml application/rss+xml
  image/svg+xml;

# Real IP can be configured later if behind Cloudflare
EOF

  # Rate limit zones (unique "dlh_*" names to avoid conflicts)
  cat >/etc/nginx/conf.d/10-dlh-limit-zones.conf <<'EOF'
limit_req_zone $binary_remote_addr zone=dlh_perip:10m rate=5r/s;
limit_req_zone $binary_remote_addr zone=dlh_login:10m rate=1r/s;
limit_conn_zone $binary_remote_addr zone=dlh_connperip:10m;
EOF

  # Snippet antibot (references ONLY dlh_* zones)
  cat >/etc/nginx/snippets/dlh-basic-antibot.conf <<'EOF'
# Connection limits
limit_conn dlh_connperip 20;

# Generic request rate limit
limit_req zone=dlh_perip burst=20 nodelay;

# Bruteforce for common login endpoints can be enabled per-site:
# location = /wp-login.php { limit_req zone=dlh_login burst=5 nodelay; }
EOF

  nginx -t
  systemctl enable --now nginx
  systemctl enable --now php*-fpm || true
}

write_fail2ban_basic() {
  # Keep it minimal; user can extend later
  cat >/etc/fail2ban/jail.d/dlh-nginx.conf <<'EOF'
[nginx-http-auth]
enabled = true
EOF
  systemctl enable --now fail2ban
}

setup_ufw_basic() {
  ufw --force enable || true
  ufw allow OpenSSH || true
  ufw allow 'Nginx Full' || true
}

install_menu() {
  local install_url menu_url
  install_url="$(cat "${INSTALL_URL_FILE}" 2>/dev/null || true)"
  menu_url="$(cat "${MENU_URL_FILE}" 2>/dev/null || true)"
  [[ -n "${install_url}" ]] || install_url="${DEFAULT_INSTALL_URL}"
  [[ -n "${menu_url}" ]] || menu_url="${DEFAULT_MENU_URL}"

  # Install/update helper commands
  cat >/usr/local/bin/dlh-update <<EOF
#!/usr/bin/env bash
set -euo pipefail
INSTALL_URL="${install_url}"
MENU_URL="${menu_url}"
curl -fsSL -H "Cache-Control: no-cache" "\${INSTALL_URL}?v=\$(date +%s)" -o /tmp/installandupdate.sh
bash /tmp/installandupdate.sh --update-only
curl -fsSL -H "Cache-Control: no-cache" "\${MENU_URL}?v=\$(date +%s)" -o /usr/local/bin/dlh
chmod +x /usr/local/bin/dlh
echo "[OK] Đã cập nhật DLH-Script."
EOF
  chmod +x /usr/local/bin/dlh-update

  # Install/update menu runner
  curl -fsSL -H "Cache-Control: no-cache" "${menu_url}?v=$(date +%s)" -o /usr/local/bin/dlh
  chmod +x /usr/local/bin/dlh
}

store_urls() {
  mkdir -p "${CONF_DIR}"
  if [[ ! -f "${INSTALL_URL_FILE}" ]]; then
    echo "${DEFAULT_INSTALL_URL}" > "${INSTALL_URL_FILE}"
  fi
  if [[ ! -f "${MENU_URL_FILE}" ]]; then
    echo "${DEFAULT_MENU_URL}" > "${MENU_URL_FILE}"
  fi
}

main() {
  local mode="${1:-}"
  ensure_dirs
  store_urls

  if [[ "${mode}" != "--update-only" ]]; then
    echo "== DLH-Script V2: Cài đặt nền tảng (Nginx/PHP/SSL/UFW/Fail2ban) =="
  fi

  apt_update_install
  write_nginx_global
  write_fail2ban_basic
  setup_ufw_basic
  install_menu

  echo
  echo "[DONE] Bạn có thể chạy menu:  dlh"
  echo "[DONE] Cập nhật từ Git:     dlh-update"
}

main "$@"
