#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/webserver-installer.conf"
INSTALL_URL="${INSTALL_URL:-}"

EMAIL=""
DOMAIN=""
ENABLE_BROTLI="0"   # default off for 1GB VPS

need_root() {
  [[ "${EUID}" -eq 0 ]] || { echo "ERROR: run with sudo"; exit 1; }
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y "$@"
}

write_file() {
  local path="$1"
  local content="$2"
  mkdir -p "$(dirname "$path")"
  printf "%s" "$content" > "$path"
}

is_ipv4() {
  [[ "$1" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]
}

load_conf_if_any() {
  if [[ -f "$CONF" ]]; then
    # shellcheck disable=SC1090
    source "$CONF" || true
    EMAIL="${EMAIL:-}"
    DOMAIN="${DOMAIN:-}"
    ENABLE_BROTLI="${ENABLE_BROTLI:-0}"
    INSTALL_URL="${INSTALL_URL:-${INSTALL_URL}}"
  fi
}

save_conf() {
  write_file "$CONF" \
"EMAIL=\"${EMAIL}\"
DOMAIN=\"${DOMAIN}\"
ENABLE_BROTLI=\"${ENABLE_BROTLI}\"
INSTALL_URL=\"${INSTALL_URL}\"
"
}

detect_domain_from_nginx() {
  local cand=""
  cand="$(grep -RhoP '^\s*server_name\s+\K[^;]+' /etc/nginx/sites-enabled 2>/dev/null | tr ' ' '\n' | grep -E '^[A-Za-z0-9.-]+$' | grep -vE '^(localhost|_)$' | head -n 1 || true)"
  if [[ -n "$cand" ]]; then
    echo "$cand"
    return
  fi

  cand="$(hostname -f 2>/dev/null || true)"
  if [[ -n "$cand" && "$cand" != "localhost" && ! "$(is_ipv4 "$cand")" ]]; then
    echo "$cand"
    return
  fi

  echo ""
}

ask_email_only() {
  echo "=== Webserver basic setup ==="

  if [[ -n "${EMAIL}" ]]; then
    echo "Current EMAIL: ${EMAIL}"
    read -r -p "Keep this email? (Y/n): " keep || true
    keep="${keep:-Y}"
    if [[ "$keep" =~ ^[Yy]$ ]]; then
      return
    fi
  fi

  read -r -p "Enter email for Let's Encrypt (e.g. admin@example.com): " e
  EMAIL="${e:-$EMAIL}"

  if [[ -z "$EMAIL" ]]; then
    echo "ERROR: Email is required."
    exit 1
  fi
}

ensure_ufw() {
  if ! command -v ufw >/dev/null 2>&1; then
    apt_install ufw
  fi
  ufw default deny incoming || true
  ufw default allow outgoing || true
  ufw allow OpenSSH || true
  ufw allow 80/tcp || true
  ufw allow 443/tcp || true
  ufw --force enable || true
}

ensure_fail2ban() {
  if ! command -v fail2ban-client >/dev/null 2>&1; then
    apt_install fail2ban
  fi
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
  if swapon --show | grep -q '^/'; then
    return
  fi
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
  # Find "gzip on;" excluding our own file (to avoid self-detection).
  # Return 0 if found elsewhere, 1 otherwise.
  local hits=""
  hits="$(grep -RIn "^\s*gzip\s\+on\s*;" /etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/sites-enabled 2>/dev/null \
    | grep -v "/etc/nginx/conf.d/01-gzip.conf" || true)"
  [[ -n "$hits" ]]
}

disable_our_gzip_conf() {
  if [[ -f /etc/nginx/conf.d/01-gzip.conf ]]; then
    mv /etc/nginx/conf.d/01-gzip.conf /etc/nginx/conf.d/01-gzip.conf.off
  fi
}

write_nginx_global_conf() {
  write_file "/etc/nginx/conf.d/00-security.conf" \
"server_tokens off;

map \$http_user_agent \$bad_ua {
  default 0;
  ~*\"(masscan|nikto|sqlmap|nmap|acunetix|wpscan|python-requests)\" 1;
}
"

  # ---- FIX: avoid duplicate gzip on; ----
  # If gzip already exists in nginx.conf or other conf files, do NOT create our gzip file.
  if gzip_already_enabled_elsewhere; then
    echo "INFO: Detected existing 'gzip on;' in current Nginx config -> skip creating /etc/nginx/conf.d/01-gzip.conf"
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

  write_file "/etc/nginx/conf.d/10-limit-zones.conf" \
"limit_req_zone \$binary_remote_addr zone=perip:10m rate=5r/s;
limit_req_zone \$binary_remote_addr zone=login:10m rate=1r/s;
limit_conn_zone \$binary_remote_addr zone=connperip:10m;
limit_conn_zone \$binary_remote_addr zone=connperip:10m;
"

  write_file "/etc/nginx/snippets/block-sensitive.conf" \
"location ~* /\\.((?!well-known).)* { deny all; }
location ~* /(\\.git|\\.svn|\\.hg|\\.env) { deny all; }
location ~* /(composer\\.(json|lock)|package\\.json|yarn\\.lock) { deny all; }
"

  write_file "/etc/nginx/snippets/basic-antibot.conf" \
"if (\$bad_ua) { return 444; }

limit_conn connperip 20;
limit_req zone=perip burst=20 nodelay;

location = /xmlrpc.php { deny all; }

location = /wp-login.php {
  limit_req zone=login burst=5 nodelay;
  try_files \$uri \$uri/ /index.php?\$args;
}
"
}

write_site_conf() {
  mkdir -p /var/www/site/public
  if [[ ! -f /var/www/site/public/index.php ]]; then
    write_file "/var/www/site/public/index.php" "<?php echo 'OK';"
  fi
  chown -R www-data:www-data /var/www/site

  local server_name="${DOMAIN:-_}"

  write_file "/etc/nginx/sites-available/site" \
"server {
  listen 80 default_server;
  listen [::]:80 default_server;

  server_name ${server_name};

  root /var/www/site/public;
  index index.php index.html;

  include /etc/nginx/snippets/block-sensitive.conf;
  include /etc/nginx/snippets/basic-antibot.conf;

  location / {
    try_files \$uri \$uri/ /index.php?\$args;
  }

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

ensure_ssl_http2_if_possible() {
  if [[ -z "${DOMAIN}" ]]; then
    echo "INFO: DOMAIN not detected -> skip SSL (Let's Encrypt needs a domain)."
    return
  fi
  if is_ipv4 "${DOMAIN}"; then
    echo "INFO: DOMAIN is an IP (${DOMAIN}) -> skip SSL (Let's Encrypt doesn't issue for IP)."
    return
  fi

  apt_install certbot python3-certbot-nginx

  set +e
  certbot --nginx \
    -d "${DOMAIN}" \
    -m "${EMAIL}" \
    --agree-tos \
    --non-interactive \
    --redirect
  local rc=$?
  set -e

  if [[ $rc -ne 0 ]]; then
    echo "WARN: SSL request failed (maybe DNS not pointed yet)."
    echo "      After DNS is ready, re-run: sudo webserver-update"
    return
  fi

  systemctl enable --now certbot.timer || true

  sed -i 's/listen 443 ssl;/listen 443 ssl http2;/' /etc/nginx/sites-enabled/site || true
  sed -i 's/listen \[::\]:443 ssl;/listen \[::\]:443 ssl http2;/' /etc/nginx/sites-enabled/site || true

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
  echo \"Reinstall using:\"
  echo \"  sudo bash -c 'INSTALL_URL=\\\"https://raw.githubusercontent.com/<user>/<repo>/main/webserver.sh\\\"; curl -fsSL \\\"\\\$INSTALL_URL\\\" -o /tmp/webserver.sh && sudo bash /tmp/webserver.sh'\"
  exit 1
fi
curl -fsSL \"\$INSTALL_URL\" -o /tmp/webserver.sh
sudo bash /tmp/webserver.sh
echo \"Update done.\"
"
  chmod +x /usr/local/bin/webserver-update
}

main() {
  need_root
  load_conf_if_any

  if [[ -z "${DOMAIN}" ]]; then
    DOMAIN="$(detect_domain_from_nginx || true)"
  fi

  ask_email_only
  save_conf

  echo "[1/6] UFW + Fail2ban + Swap"
  apt_install software-properties-common
  ensure_ufw
  ensure_fail2ban
  ensure_swap_2g

  echo "[2/6] Nginx + PHP"
  ensure_nginx_php

  echo "[3/6] Nginx global configs (gzip/limits/security)"
  write_nginx_global_conf

  echo "[4/6] Site config"
  write_site_conf

  echo "[5/6] SSL + HTTP/2 (auto if domain detected)"
  ensure_ssl_http2_if_possible

  echo "[6/6] Logrotate + update command"
  ensure_logrotate_nginx
  install_update_cmd

  echo "DONE ✅"
  echo "- Update later: sudo webserver-update"
  echo "- Check: sudo nginx -t"
}

main
