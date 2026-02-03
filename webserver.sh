#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# DLH Webserver Basic Installer (Ubuntu 24.04 / 1GB RAM)
# - Nginx + PHP-FPM
# - UFW + Fail2ban + Swap
# - gzip (skip if already enabled) + anti-bot + rate-limit (zones)
# - logrotate
# - NO domain auto-detect, NO SSL auto (domain empty is OK)
# - Installs "dlh" menu like HOCVPS
# - Installs "webserver-update" to self-update from GitHub raw URL
#
# Run (recommended):
#   curl -fsSL <RAW_URL>/webserver.sh | sudo INSTALL_URL="<RAW_URL>/webserver.sh" bash
# =========================================================

CONF="/etc/webserver-installer.conf"
INSTALL_URL="${INSTALL_URL:-}"

ZONE_CONN="dlh_connperip"  # unique to avoid conflicts

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

save_conf() {
  write_file "$CONF" \
"INSTALL_URL=\"${INSTALL_URL}\"
ZONE_CONN=\"${ZONE_CONN}\"
"
}

# ---------------------------
# Base security & stability
# ---------------------------
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

# ---------------------------
# Nginx + PHP
# ---------------------------
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
}

ensure_limit_zones() {
  # Always overwrite our zones to avoid duplicates.
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

# Mild global limiting (safe defaults for 1GB)
limit_conn ${ZONE_CONN} 20;
limit_req zone=perip burst=20 nodelay;

# Common abuse endpoints (WP)
location = /xmlrpc.php { deny all; }

location = /wp-login.php {
  limit_req zone=login burst=5 nodelay;
  try_files \$uri \$uri/ /index.php?\$args;
}
"
}

write_default_site_conf() {
  # Default catch-all site with NO domain
  mkdir -p /var/www/site/public
  if [[ ! -f /var/www/site/public/index.php ]]; then
    write_file "/var/www/site/public/index.php" "<?php echo 'OK';"
  fi
  chown -R www-data:www-data /var/www/site

  write_file "/etc/nginx/sites-available/site" \
"server {
  listen 80 default_server;
  listen [::]:80 default_server;

  server_name _;

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

# ---------------------------
# DLH Menu (hocvps-like)
# ---------------------------
install_dlh_menu() {
  cat >/usr/local/bin/dlh <<'SH'
#!/usr/bin/env bash
set -euo pipefail

CONF="/etc/dlh-menu.conf"
ROOT_BASE_DEFAULT="/var/www"
PHP_SOCK="/run/php/php8.3-fpm.sock"

read_tty() {
  local prompt="$1"
  local var=""
  if [[ -r /dev/tty ]]; then
    IFS= read -r -p "$prompt" var </dev/tty || true
  else
    IFS= read -r -p "$prompt" var || true
  fi
  printf "%s" "$var"
}

# allow running just "dlh" (auto sudo)
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
}

save_conf() {
  cat >"$CONF" <<EOF
INSTALL_URL="${INSTALL_URL}"
ROOT_BASE="${ROOT_BASE}"
ZONE_CONN="${ZONE_CONN}"
EOF
}

nginx_reload() {
  nginx -t && systemctl reload nginx
}

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

add_domain() {
  ensure_snippets

  local domain
  domain="$(read_tty "Domain (e.g. example.com): ")"
  domain="${domain,,}"
  [[ -n "$domain" ]] || { echo "ERROR: domain empty"; return; }

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
  echo "OK: Added domain ${domain}"
  echo "Webroot: ${webroot}"
}

install_ssl() {
  local domain email
  domain="$(read_tty "Domain for SSL (e.g. example.com): ")"
  domain="${domain,,}"
  [[ -n "$domain" ]] || { echo "ERROR: domain empty"; return; }

  email="$(read_tty "Email for Let's Encrypt: ")"
  [[ -n "$email" ]] || { echo "ERROR: email empty"; return; }

  apt-get update -y
  apt-get install -y certbot python3-certbot-nginx

  certbot --nginx -d "$domain" -d "www.$domain" -m "$email" --agree-tos --non-interactive --redirect || {
    echo "SSL failed. Check DNS/Cloudflare and ensure port 80 reachable."
    return
  }

  systemctl enable --now certbot.timer || true

  # best-effort enable HTTP/2
  sed -i 's/listen 443 ssl;/listen 443 ssl http2;/' /etc/nginx/sites-enabled/*.conf 2>/dev/null || true
  sed -i 's/listen \[::\]:443 ssl;/listen [::]:443 ssl http2;/' /etc/nginx/sites-enabled/*.conf 2>/dev/null || true

  nginx_reload
  echo "OK: SSL installed for https://${domain}"
}

install_wpcli() {
  if command -v wp >/dev/null 2>&1; then
    echo "WP-CLI already installed: $(wp --version)"
    return
  fi
  apt-get update -y
  apt-get install -y curl php-cli
  curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /tmp/wp-cli.phar
  php /tmp/wp-cli.phar --info >/dev/null
  chmod +x /tmp/wp-cli.phar
  mv /tmp/wp-cli.phar /usr/local/bin/wp
  echo "OK: WP-CLI installed: $(wp --version)"
}

wp_download() {
  local domain dir
  domain="$(read_tty "Domain (must exist in ${ROOT_BASE}/<domain>/public): ")"
  domain="${domain,,}"
  dir="${ROOT_BASE}/${domain}/public"
  if [[ ! -d "$dir" ]]; then
    echo "ERROR: webroot not found: $dir"
    echo "Tip: use 1) Add Domain first."
    return
  fi

  install_wpcli

  if [[ -f "${dir}/wp-config.php" || -d "${dir}/wp-admin" ]]; then
    echo "Looks like WordPress already exists in $dir (skip)."
    return
  fi

  rm -f "${dir}/index.php" 2>/dev/null || true
  chown -R www-data:www-data "$dir"
  sudo -u www-data wp core download --path="$dir" --locale=vi --skip-content
  echo "OK: Downloaded WordPress to $dir"
}

wp_fixperm() {
  local domain dir
  domain="$(read_tty "Domain: ")"
  domain="${domain,,}"
  dir="${ROOT_BASE}/${domain}"
  if [[ ! -d "$dir" ]]; then
    echo "ERROR: not found: $dir"
    return
  fi
  chown -R www-data:www-data "$dir"
  find "$dir" -type d -exec chmod 755 {} \;
  find "$dir" -type f -exec chmod 644 {} \;
  echo "OK: Permissions fixed: $dir"
}

wp_menu() {
  while true; do
    echo
    echo "=== WordPress utilities ==="
    echo "1) Install WP-CLI"
    echo "2) Download WordPress (vi) to domain webroot"
    echo "3) Fix permissions (www-data)"
    echo "0) Back"
    local c
    c="$(read_tty "Choose: ")"
    case "$c" in
      1) install_wpcli ;;
      2) wp_download ;;
      3) wp_fixperm ;;
      0) return ;;
      *) echo "Invalid." ;;
    esac
  done
}

nginx_tools() {
  echo
  echo "--- nginx -t ---"
  nginx -t || true
  echo
  echo "--- status nginx/php-fpm ---"
  systemctl status nginx php8.3-fpm --no-pager || true
}

set_root_base() {
  local v
  v="$(read_tty "ROOT_BASE (current: ${ROOT_BASE}): ")"
  [[ -n "$v" ]] && ROOT_BASE="$v"
  save_conf
  echo "OK: ROOT_BASE=${ROOT_BASE}"
}

set_update_url() {
  local url
  url="$(read_tty "Raw URL for update (installer) (e.g. https://raw.githubusercontent.com/<user>/<repo>/main/webserver.sh): ")"
  INSTALL_URL="$url"
  save_conf
  echo "OK: saved INSTALL_URL"
}

run_update() {
  if [[ -z "${INSTALL_URL}" ]]; then
    echo "INSTALL_URL is empty. Choose option to set it first."
    return
  fi
  curl -fsSL "$INSTALL_URL" | sudo INSTALL_URL="$INSTALL_URL" bash
  echo "OK: updated from $INSTALL_URL"
}

main_menu() {
  while true; do
    echo
    echo "==================== DLH MENU ===================="
    echo "1) Add Domain (Nginx vhost + webroot)"
    echo "2) Install SSL (Let's Encrypt + HTTP/2 + auto renew)"
    echo "3) WordPress utilities"
    echo "4) Nginx tools (test/status)"
    echo "5) Update installer from GitHub"
    echo "6) Set update URL"
    echo "7) Set ROOT_BASE (web root folder)"
    echo "0) Exit"
    echo "=================================================="
    local choice
    choice="$(read_tty "Choose: ")"
    case "$choice" in
      1) add_domain ;;
      2) install_ssl ;;
      3) wp_menu ;;
      4) nginx_tools ;;
      5) run_update ;;
      6) set_update_url ;;
      7) set_root_base ;;
      0) exit 0 ;;
      *) echo "Invalid choice." ;;
    esac
  done
}

load_conf
main_menu
SH

  chmod +x /usr/local/bin/dlh
}

# ---------------------------
# Updater command
# ---------------------------
install_update_cmd() {
  write_file "/usr/local/bin/webserver-update" \
"#!/usr/bin/env bash
set -euo pipefail
source /etc/webserver-installer.conf || true
if [[ -z \"\${INSTALL_URL:-}\" ]]; then
  echo \"INSTALL_URL is empty.\"
  echo \"Run installer once with:\"
  echo \"  curl -fsSL <raw>/webserver.sh | sudo INSTALL_URL='<raw>/webserver.sh' bash\"
  exit 1
fi
curl -fsSL \"\$INSTALL_URL\" | sudo INSTALL_URL=\"\$INSTALL_URL\" bash
echo \"Update done.\"
"
  chmod +x /usr/local/bin/webserver-update
}

# ---------------------------
# Main
# ---------------------------
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

  echo "[3/6] Nginx global configs (gzip/limits/security)"
  write_nginx_global_conf

  echo "[4/6] Default site (no domain)"
  write_default_site_conf

  echo "[5/6] Logrotate"
  ensure_logrotate_nginx

  echo "[6/6] Install menu + updater"
  install_dlh_menu
  install_update_cmd

  echo "DONE ✅"
  echo "- Run menu: dlh"
  echo "- Test local: curl -I http://127.0.0.1"
  echo "- Update later: sudo webserver-update"
}

main
