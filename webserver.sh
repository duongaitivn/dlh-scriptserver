#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# Basic Webserver Bootstrap for Ubuntu 24.04 (1GB RAM friendly)
# - Nginx + PHP-FPM
# - Let's Encrypt (Certbot) + auto renew
# - HTTP/2 + gzip + optional brotli
# - logrotate + basic anti-bot + rate limiting
# =========================================================

DOMAIN=""
EMAIL=""
ENABLE_BROTLI="0"

# Optional: store where this script was fetched from (for updates)
INSTALL_URL="${INSTALL_URL:-}"

usage() {
  cat <<EOF
Usage:
  sudo bash webserver.sh --domain example.com --email admin@example.com [--with-brotli]

Options:
  --domain         Domain for the website (A record must point to this VPS)
  --email          Email for Let's Encrypt registration
  --with-brotli    Install and enable brotli (optional)
  -h, --help       Show help
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --domain) DOMAIN="${2:-}"; shift 2 ;;
    --email) EMAIL="${2:-}"; shift 2 ;;
    --with-brotli) ENABLE_BROTLI="1"; shift 1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "Unknown arg: $1"; usage; exit 1 ;;
  esac
done

if [[ -z "${DOMAIN}" || -z "${EMAIL}" ]]; then
  echo "ERROR: --domain and --email are required"
  usage
  exit 1
fi

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "ERROR: Please run as root (sudo)."
    exit 1
  fi
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
  # Only create swap if no swap exists
  if swapon --show | grep -q '^/'; then
    return
  fi

  # Create 2G swapfile (good for 1GB RAM VPS)
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile

  if ! grep -q '^/swapfile' /etc/fstab; then
    echo '/swapfile none swap sw 0 0' >> /etc/fstab
  fi

  write_file "/etc/sysctl.d/99-swappiness.conf" "vm.swappiness=10
"
  sysctl -p /etc/sysctl.d/99-swappiness.conf >/dev/null || true
}

ensure_nginx_php() {
  apt_install nginx

  # PHP 8.3 packages on Ubuntu 24.04
  apt_install php-fpm php-cli php-mysql php-curl php-mbstring php-xml php-zip php-gd php-intl

  systemctl enable --now nginx
  systemctl enable --now php8.3-fpm

  # PHP-FPM tuning for 1GB RAM
  local pool="/etc/php/8.3/fpm/pool.d/www.conf"
  if [[ -f "$pool" ]]; then
    # Replace or add key settings (safe edits)
    sed -i 's/^pm = .*/pm = ondemand/' "$pool" || true
    sed -i 's/^;*pm\.max_children = .*/pm.max_children = 8/' "$pool" || true
    sed -i 's/^;*pm\.process_idle_timeout = .*/pm.process_idle_timeout = 10s/' "$pool" || true
    sed -i 's/^;*pm\.max_requests = .*/pm.max_requests = 300/' "$pool" || true
  fi

  systemctl restart php8.3-fpm
}

enable_brotli() {
  if [[ "$ENABLE_BROTLI" != "1" ]]; then
    return
  fi

  # Module package (Ubuntu repo)
  apt_install libnginx-mod-brotli || true

  # Create brotli conf only if module appears enabled
  if ls /etc/nginx/modules-enabled/*brotli*.conf >/dev/null 2>&1; then
    write_file "/etc/nginx/conf.d/02-brotli.conf" \
"brotli on;
brotli_comp_level 5;
brotli_types
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
}

write_nginx_global_conf() {
  # Security + gzip + rate-limit zones (http context via conf.d)
  write_file "/etc/nginx/conf.d/00-security.conf" \
"server_tokens off;

# Drop some noisy scanners early
map \$http_user_agent \$bad_ua {
  default 0;
  ~*\"(masscan|nikto|sqlmap|nmap|acunetix|wpscan|curl|python-requests)\" 1;
}
"

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

  # Rate-limit zones must be in http context
  write_file "/etc/nginx/conf.d/10-limit-zones.conf" \
"limit_req_zone \$binary_remote_addr zone=perip:10m rate=5r/s;
limit_req_zone \$binary_remote_addr zone=login:10m rate=1r/s;
limit_conn_zone \$binary_remote_addr zone=connperip:10m;
"

  # Sensitive file block snippet (included inside server)
  write_file "/etc/nginx/snippets/block-sensitive.conf" \
"location ~* /\\.((?!well-known).)* { deny all; }
location ~* /(\\.git|\\.svn|\\.hg|\\.env) { deny all; }
location ~* /(composer\\.(json|lock)|package\\.json|yarn\\.lock) { deny all; }
"

  # Basic anti-bot + limit rules snippet (included inside server)
  write_file "/etc/nginx/snippets/basic-antibot.conf" \
"if (\$bad_ua) { return 444; }

# General request limiting (keep it mild)
limit_conn connperip 20;
limit_req zone=perip burst=20 nodelay;

# Common abuse endpoints (WordPress)
location = /xmlrpc.php { deny all; }

# Stricter limit for login endpoint (won't affect normal browsing)
location = /wp-login.php {
  limit_req zone=login burst=5 nodelay;
  try_files \$uri \$uri/ /index.php?\$args;
}
"
}

write_nginx_site_conf() {
  mkdir -p /var/www/site/public
  if [[ ! -f /var/www/site/public/index.php ]]; then
    write_file "/var/www/site/public/index.php" "<?php echo 'OK';"
  fi
  chown -R www-data:www-data /var/www/site

  # Nginx site for domain (HTTP first; certbot will add HTTPS + redirect)
  write_file "/etc/nginx/sites-available/site" \
"server {
  listen 80;
  listen [::]:80;

  server_name ${DOMAIN};

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

  # Enable site
  rm -f /etc/nginx/sites-enabled/default || true
  ln -sf /etc/nginx/sites-available/site /etc/nginx/sites-enabled/site

  nginx -t
  systemctl reload nginx
}

ensure_certbot_ssl() {
  apt_install certbot python3-certbot-nginx

  # Obtain/renew cert non-interactively and redirect HTTP->HTTPS
  certbot --nginx \
    -d "${DOMAIN}" \
    -m "${EMAIL}" \
    --agree-tos \
    --non-interactive \
    --redirect

  # Ensure certbot auto renew timer
  systemctl enable --now certbot.timer || true

  # Force HTTP/2 on 443 if certbot didn't add it
  # Find any "listen 443 ssl;" and add http2
  local conf="/etc/nginx/sites-enabled/site"
  if [[ -f "$conf" ]]; then
    sed -i 's/listen 443 ssl;/listen 443 ssl http2;/' "$conf" || true
    sed -i 's/listen \[::\]:443 ssl;/listen \[::\]:443 ssl http2;/' "$conf" || true
  fi

  nginx -t
  systemctl reload nginx
}

ensure_logrotate_nginx() {
  # Override or add a stronger logrotate policy for nginx logs
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

install_update_helper() {
  # Save install url to config for later updates, if provided
  if [[ -n "${INSTALL_URL}" ]]; then
    write_file "/etc/webserver-installer.conf" "INSTALL_URL=\"${INSTALL_URL}\"
"
  else
    # Keep existing if already present
    if [[ ! -f /etc/webserver-installer.conf ]]; then
      write_file "/etc/webserver-installer.conf" "INSTALL_URL=\"\"
"
    fi
  fi

  # Create updater command: webserver-update
  write_file "/usr/local/bin/webserver-update" \
"#!/usr/bin/env bash
set -euo pipefail
source /etc/webserver-installer.conf || true
if [[ -z \"\${INSTALL_URL:-}\" ]]; then
  echo \"INSTALL_URL is empty. Re-run installer with INSTALL_URL env set.\"
  echo \"Example:\"
  echo \"  sudo INSTALL_URL=\\\"https://raw.githubusercontent.com/<user>/<repo>/main/webserver.sh\\\" bash -c 'curl -fsSL \\\"\\\$INSTALL_URL\\\" | bash -s -- --domain ${DOMAIN} --email ${EMAIL}'\"
  exit 1
fi
curl -fsSL \"\$INSTALL_URL\" | sudo bash -s -- --domain \"${DOMAIN}\" --email \"${EMAIL}\" $( [[ "${ENABLE_BROTLI}" == "1" ]] && echo "--with-brotli" )
echo \"Update done.\"
"
  chmod +x /usr/local/bin/webserver-update
}

main() {
  need_root

  echo "[1/8] Base packages + firewall + fail2ban + swap"
  apt_install software-properties-common
  ensure_ufw
  ensure_fail2ban
  ensure_swap_2g

  echo "[2/8] Nginx + PHP-FPM"
  ensure_nginx_php

  echo "[3/8] Nginx global configs (security/gzip/limits)"
  write_nginx_global_conf

  echo "[4/8] Optional brotli"
  enable_brotli

  echo "[5/8] Site config (HTTP)"
  write_nginx_site_conf

  echo "[6/8] SSL (Let's Encrypt) + HTTP/2 + auto renew"
  ensure_certbot_ssl

  echo "[7/8] Logrotate nginx"
  ensure_logrotate_nginx

  echo "[8/8] Install update helper"
  install_update_helper

  echo "DONE."
  echo "- Website: https://${DOMAIN}"
  echo "- Test: curl -I https://${DOMAIN}"
  echo "- Update later: sudo webserver-update"
  echo "- Certbot timer: systemctl status certbot.timer"
}

main
