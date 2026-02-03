#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# DLH Webserver Basic Installer (Ubuntu 24.04 / 1GB RAM)
# - Nginx + PHP-FPM
# - UFW + Fail2ban + Swap
# - gzip (skip if already enabled) + anti-bot + rate-limit zones
# - logrotate
# - NO domain auto-detect, NO SSL auto
# - Installs "dlh" menu (HOCVPS-like UI)
# - Installs "webserver-update" to self-update from GitHub raw URL
#
# Run:
#   curl -fsSL <RAW>/webserver.sh | sudo INSTALL_URL="<RAW>/webserver.sh" bash
# =========================================================

CONF="/etc/webserver-installer.conf"
INSTALL_URL="${INSTALL_URL:-}"
ZONE_CONN="dlh_connperip"

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
  swapon --show | grep -q '^/' && return
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

# FIX: Must NOT exit when file doesn't exist under "set -e"
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
  mkdir -p /var/www/site/public
  [[ -f /var/www/site/public/index.php ]] || write_file "/var/www/site/public/index.php" "<?php echo 'OK';"
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
ROOT_BASE_DEFAULT="/var/www"
PHP_SOCK="/run/php/php8.3-fpm.sock"

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
pause() { read_tty "Press Enter to continue..."; }

banner() {
  clear_screen
  printf "%s%sDLH SERVER TOOLKIT%s\n" "$C_BOLD" "$C_CYA" "$C_RESET"
  printf "%sBasic Webserver (Nginx/PHP/SSL/WP) - menu style like HOCVPS%s\n" "$C_DIM" "$C_RESET"
  hr
}

msg_ok()   { printf "%s[OK]%s %s\n"   "$C_GRN" "$C_RESET" "$*"; }
msg_warn() { printf "%s[WARN]%s %s\n" "$C_YEL" "$C_RESET" "$*"; }
msg_err()  { printf "%s[ERR]%s %s\n"  "$C_RED" "$C_RESET" "$*"; }

# auto sudo
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

# ---------- Actions ----------
add_domain() {
  ensure_snippets
  local domain
  domain="$(read_tty "Domain (e.g. example.com): ")"
  domain="${domain,,}"
  [[ -n "$domain" ]] || { msg_err "Domain empty"; return; }

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
  msg_ok "Added domain: ${domain}"
  msg_ok "Webroot: ${webroot}"
}

# DNS check without extra packages:
dns_exists() {
  local host="$1"
  getent ahosts "$host" >/dev/null 2>&1
}

install_ssl() {
  local domain email
  domain="$(read_tty "Domain for SSL (e.g. example.com): ")"
  domain="${domain,,}"
  [[ -n "$domain" ]] || { msg_err "Domain empty"; return; }

  email="$(read_tty "Email for Let's Encrypt: ")"
  [[ -n "$email" ]] || { msg_err "Email empty"; return; }

  apt-get update -y
  apt-get install -y certbot python3-certbot-nginx

  local args=(-d "$domain")
  if getent ahosts "www.${domain}" >/dev/null 2>&1; then
    args+=(-d "www.${domain}")
    msg_ok "DNS OK: www.${domain} exists -> include www"
  else
    msg_warn "DNS missing: www.${domain} (NXDOMAIN) -> skip www"
  fi

  if ! certbot --nginx "${args[@]}" -m "$email" --agree-tos --non-interactive --redirect; then
    msg_warn "SSL failed. Check DNS/Cloudflare and ensure port 80 reachable."
    return
  fi

  systemctl enable --now certbot.timer || true

  sed -i 's/listen 443 ssl;/listen 443 ssl http2;/' /etc/nginx/sites-enabled/*.conf 2>/dev/null || true
  sed -i 's/listen \[::\]:443 ssl;/listen [::]:443 ssl http2;/' /etc/nginx/sites-enabled/*.conf 2>/dev/null || true

  nginx_reload
  msg_ok "SSL installed."
  msg_ok "Domain: https://${domain}"
}

install_wpcli() {
  if command -v wp >/dev/null 2>&1; then
    msg_ok "WP-CLI already installed: $(wp --version)"
    return
  fi
  apt-get update -y
  apt-get install -y curl php-cli
  curl -fsSL https://raw.githubusercontent.com/wp-cli/builds/gh-pages/phar/wp-cli.phar -o /tmp/wp-cli.phar
  php /tmp/wp-cli.phar --info >/dev/null
  chmod +x /tmp/wp-cli.phar
  mv /tmp/wp-cli.phar /usr/local/bin/wp
  msg_ok "WP-CLI installed: $(wp --version)"
}

wp_download() {
  local domain dir
  domain="$(read_tty "Domain (must exist in ${ROOT_BASE}/<domain>/public): ")"
  domain="${domain,,}"
  dir="${ROOT_BASE}/${domain}/public"
  [[ -d "$dir" ]] || { msg_err "Webroot not found: $dir (Add Domain first)"; return; }

  install_wpcli

  if [[ -f "${dir}/wp-config.php" || -d "${dir}/wp-admin" ]]; then
    msg_warn "WordPress seems already exists in $dir (skip)."
    return
  fi

  rm -f "${dir}/index.php" 2>/dev/null || true
  chown -R www-data:www-data "$dir"
  sudo -u www-data wp core download --path="$dir" --locale=vi --skip-content
  msg_ok "Downloaded WordPress (vi) to $dir"
}

wp_fixperm() {
  local domain dir
  domain="$(read_tty "Domain: ")"
  domain="${domain,,}"
  dir="${ROOT_BASE}/${domain}"
  [[ -d "$dir" ]] || { msg_err "Not found: $dir"; return; }

  chown -R www-data:www-data "$dir"
  find "$dir" -type d -exec chmod 755 {} \;
  find "$dir" -type f -exec chmod 644 {} \;
  msg_ok "Fixed permissions: $dir"
}

wp_menu() {
  while true; do
    banner
    printf "%s%s[WORDPRESS]%s\n" "$C_BOLD" "$C_BLU" "$C_RESET"
    echo "1) Install WP-CLI"
    echo "2) Download WordPress (vi) to domain webroot"
    echo "3) Fix permissions (www-data)"
    echo "0) Back"
    hr
    case "$(read_tty "Choose: ")" in
      1) install_wpcli; pause ;;
      2) wp_download; pause ;;
      3) wp_fixperm; pause ;;
      0) return ;;
      *) msg_warn "Invalid"; pause ;;
    esac
  done
}

nginx_tools() {
  banner
  echo "${C_BOLD}nginx -t${C_RESET}"
  nginx -t || true
  echo
  echo "${C_BOLD}status nginx/php-fpm${C_RESET}"
  systemctl status nginx php8.3-fpm --no-pager || true
  hr
  pause
}

set_update_url() {
  local url
  url="$(read_tty "Installer RAW URL (webserver.sh): ")"
  INSTALL_URL="$url"
  save_conf
  msg_ok "Saved INSTALL_URL"
}

run_update() {
  if command -v webserver-update >/dev/null 2>&1; then
    webserver-update
    msg_ok "Updated via webserver-update"
    return
  fi
  if [[ -z "${INSTALL_URL}" ]]; then
    msg_err "INSTALL_URL empty. Set it first."
    return
  fi
  curl -fsSL "$INSTALL_URL" | sudo INSTALL_URL="$INSTALL_URL" bash
  msg_ok "Updated from $INSTALL_URL"
}

set_root_base() {
  local v
  v="$(read_tty "ROOT_BASE (current: ${ROOT_BASE}): ")"
  [[ -n "$v" ]] && ROOT_BASE="$v"
  save_conf
  msg_ok "ROOT_BASE=${ROOT_BASE}"
}

menu_domain_ssl() {
  while true; do
    banner
    printf "%s%s[DOMAIN / SSL]%s\n" "$C_BOLD" "$C_BLU" "$C_RESET"
    echo "1) Add Domain (Nginx vhost + webroot)"
    echo "2) Install SSL (Let's Encrypt + HTTP/2 + auto renew)"
    echo "0) Back"
    hr
    case "$(read_tty "Choose: ")" in
      1) add_domain; pause ;;
      2) install_ssl; pause ;;
      0) return ;;
      *) msg_warn "Invalid"; pause ;;
    esac
  done
}

menu_system() {
  while true; do
    banner
    printf "%s%s[SYSTEM / TOOLS]%s\n" "$C_BOLD" "$C_BLU" "$C_RESET"
    echo "1) Nginx tools (test/status)"
    echo "2) Update installer from GitHub"
    echo "3) Set update URL"
    echo "4) Set ROOT_BASE"
    echo "0) Back"
    hr
    case "$(read_tty "Choose: ")" in
      1) nginx_tools ;;
      2) run_update; pause ;;
      3) set_update_url; pause ;;
      4) set_root_base; pause ;;
      0) return ;;
      *) msg_warn "Invalid"; pause ;;
    esac
  done
}

main_menu() {
  while true; do
    banner
    echo "1) Domain / SSL"
    echo "2) WordPress"
    echo "3) System / Tools"
    echo "0) Exit"
    hr
    case "$(read_tty "Choose: ")" in
      1) menu_domain_ssl ;;
      2) wp_menu ;;
      3) menu_system ;;
      0) exit 0 ;;
      *) msg_warn "Invalid"; pause ;;
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
}

main
