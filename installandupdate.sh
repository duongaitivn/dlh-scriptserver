#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# DLH-Script V2 — install + update (Ubuntu 24.04, VPS nhỏ)
# Repo structure (2 files):
#   - installandupdate.sh   (this file)
#   - dlh-script.sh         (menu; installed as /usr/local/bin/dlh)
#
# Install:
#   curl -fsSL <RAW>/installandupdate.sh | sudo INSTALL_URL="<RAW>/installandupdate.sh" bash
#
# Update later:
#   sudo dlh-update
# =========================================================

CONF="/etc/dlh-installer.conf"
DEFAULT_ROOT_BASE="/home/www"
ZONE_CONN="dlh_connperip"
INSTALL_URL="${INSTALL_URL:-}"

need_root() { [[ "${EUID}" -eq 0 ]] || { echo "ERROR: run with sudo"; exit 1; }; }

ensure_apt_ipv4() {
  mkdir -p /etc/apt/apt.conf.d
  printf 'Acquire::ForceIPv4 "true";\n' > /etc/apt/apt.conf.d/99force-ipv4
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  ensure_apt_ipv4
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
DEFAULT_ROOT_BASE=\"${DEFAULT_ROOT_BASE}\"
ZONE_CONN=\"${ZONE_CONN}\"
"
}

install_update_cmd() {
  write_file "/usr/local/bin/dlh-update" \
'#!/usr/bin/env bash
set -euo pipefail
source /etc/dlh-installer.conf || true
if [[ -z "${INSTALL_URL:-}" ]]; then
  echo "INSTALL_URL is empty."
  echo "Run once with:"
  echo "  curl -fsSL <raw>/installandupdate.sh | sudo INSTALL_URL=\"<raw>/installandupdate.sh\" bash"
  exit 1
fi
curl -fsSL "$INSTALL_URL" | sudo INSTALL_URL="$INSTALL_URL" bash
echo "Update done."
'
  chmod +x /usr/local/bin/dlh-update
}

install_menu_from_repo() {
  if [[ -z "${INSTALL_URL}" ]]; then
    echo "ERROR: INSTALL_URL is empty (need raw GitHub URL)."
    exit 1
  fi

  local base_url menu_url
  base_url="$(dirname "$INSTALL_URL")"
  menu_url="${base_url}/dlh-script.sh"

  mkdir -p /usr/local/bin
  apt_install curl ca-certificates

  if ! curl -fsSL "$menu_url" -o /usr/local/bin/dlh; then
    echo "ERROR: cannot download dlh-script.sh from: $menu_url"
    echo "Ensure repo has dlh-script.sh next to installandupdate.sh"
    exit 1
  fi
  chmod +x /usr/local/bin/dlh
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

  # PHP-FPM tune for 1GB
  local pool="/etc/php/8.3/fpm/pool.d/www.conf"
  if [[ -f "$pool" ]]; then
    sed -i 's/^pm = .*/pm = ondemand/' "$pool" || true
    sed -i 's/^;*pm\.max_children = .*/pm.max_children = 8/' "$pool" || true
    sed -i 's/^;*pm\.process_idle_timeout = .*/pm.process_idle_timeout = 10s/' "$pool" || true
    sed -i 's/^;*pm\.max_requests = .*/pm.max_requests = 300/' "$pool" || true
  fi
  systemctl restart php8.3-fpm
}

write_nginx_basics() {

  # migrate legacy snippets using old zone names (perip/login) -> dlh_perip/dlh_login
  if [[ -d "/etc/nginx/snippets" ]]; then
    for f in /etc/nginx/snippets/*.conf; do
      [[ -f "$f" ]] || continue
      # backup once per run if we will change
      if grep -qE 'zone=(perip|login)\b' "$f" 2>/dev/null; then
        cp -a "$f" "${f}.bak.$(date +%s)" || true
        sed -i 's/zone=perip/zone=dlh_perip/g; s/zone=login/zone=dlh_login/g' "$f" || true
      fi
      # also handle uppercase variants
      if grep -qE 'zone=(Perip|Login)\b' "$f" 2>/dev/null; then
        cp -a "$f" "${f}.bak.$(date +%s)" || true
        sed -i 's/zone=Perip/zone=dlh_perip/g; s/zone=Login/zone=dlh_login/g' "$f" || true
      fi
    done
  fi


  # cleanup legacy server_tokens duplication (safe)
  local st_hits=""
  st_hits="$(grep -RInE '^[[:space:]]*server_tokens[[:space:]]' /etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/sites-enabled 2>/dev/null || true)"
  if [[ -n "$st_hits" ]]; then
    local st_count
    st_count="$(printf "%s\n" "$st_hits" | wc -l | tr -d ' ')"
    if [[ "${st_count}" -gt 1 && -f "/etc/nginx/conf.d/00-security.conf" ]]; then
      cp -a "/etc/nginx/conf.d/00-security.conf" "/etc/nginx/conf.d/00-security.conf.bak.$(date +%s)" || true
      sed -i '/^[[:space:]]*server_tokens[[:space:]]/d' "/etc/nginx/conf.d/00-security.conf" || true
    fi
  fi

  mkdir -p /etc/nginx/snippets

  write_file "/etc/nginx/snippets/dlh-block-sensitive.conf" \
"location ~* /\\.((?!well-known).)* { deny all; }
location ~* /(\\.git|\\.svn|\\.hg|\\.env) { deny all; }
location ~* /(composer\\.(json|lock)|package\\.json|yarn\\.lock) { deny all; }
"

  write_file "/etc/nginx/snippets/dlh-basic-antibot.conf" \
"limit_conn ${ZONE_CONN} 20;
location = /xmlrpc.php { deny all; }
location = /wp-login.php { try_files \$uri \$uri/ /index.php?\$args; }
"

  # rate limit zones + UA block
  write_file "/etc/nginx/conf.d/10-dlh-limit-zones.conf" \
"limit_req_zone \$binary_remote_addr zone=dlh_perip:10m rate=5r/s;
limit_req_zone \$binary_remote_addr zone=dlh_login:10m rate=1r/s;
limit_conn_zone \$binary_remote_addr zone=${ZONE_CONN}:10m;
"

  write_file "/etc/nginx/conf.d/00-dlh-security.conf" \
"server_tokens off;
map \$http_user_agent \$bad_ua {
  default 0;
  ~*\"(masscan|nikto|sqlmap|nmap|acunetix|wpscan|python-requests)\" 1;
}
"

  # gzip (only if not already enabled elsewhere)
  local hits=""
  hits="$(grep -RIn "^\s*gzip\s\+on\s*;" /etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/sites-enabled 2>/dev/null | grep -v "/etc/nginx/conf.d/01-dlh-gzip.conf" || true)"
  if [[ -z "$hits" ]]; then
    write_file "/etc/nginx/conf.d/01-dlh-gzip.conf" \
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

  nginx -t
  systemctl reload nginx
}

write_default_site() {
  mkdir -p "${DEFAULT_ROOT_BASE}/site/public_html"
  [[ -f "${DEFAULT_ROOT_BASE}/site/public_html/index.php" ]] || write_file "${DEFAULT_ROOT_BASE}/site/public_html/index.php" "<?php echo 'OK';"
  chown -R www-data:www-data "${DEFAULT_ROOT_BASE}/site"

  write_file "/etc/nginx/sites-available/site" \
"server {
  listen 80 default_server;
  listen [::]:80 default_server;
  server_name _;
  root ${DEFAULT_ROOT_BASE}/site/public_html;
  index index.php index.html;

  include /etc/nginx/snippets/dlh-block-sensitive.conf;
  include /etc/nginx/snippets/dlh-basic-antibot.conf;

  location / { try_files \$uri \$uri/ /index.php?\$args; }

  location ~ \\.php$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:/run/php/php8.3-fpm.sock;
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

ensure_dlh_dirs() {
  mkdir -p /var/lib/dlh/secrets /var/lib/dlh
  chmod 700 /var/lib/dlh/secrets || true
  if [[ ! -f /var/lib/dlh/manifest.json ]]; then
    printf '{"sites":[]}\n' > /var/lib/dlh/manifest.json
  fi
}

main() {
  need_root
  ensure_apt_ipv4
  save_conf

  echo "[1/8] Base hardening"
  apt_install software-properties-common
  ensure_ufw
  ensure_fail2ban
  ensure_swap_2g

  echo "[2/8] Nginx + PHP"
  ensure_nginx_php

  echo "[3/8] Nginx basics"
  fix_legacy_nginx_zones_
  write_nginx_basics

  echo "[4/8] Default site (no domain)"
  write_default_site

  echo "[5/8] Logrotate"
  ensure_logrotate_nginx

  echo "[6/8] DLH runtime dirs"
  ensure_dlh_dirs

  echo "[7/8] Install menu (dlh) from repo"
  install_menu_from_repo

  echo "[8/8] Install updater"
  install_update_cmd

  echo "DONE ✅"
  echo "- Run menu: dlh"
  echo "- Update later: sudo dlh-update"
  echo "- Default webroot base: ${DEFAULT_ROOT_BASE}"
}

fix_legacy_nginx_zones_() {
  # Dọn các file cũ gây lỗi trùng/zone perip/login
  if [[ -f /etc/nginx/conf.d/10-limit-zones.conf && ! -f /etc/nginx/conf.d/10-limit-zones.conf.bak ]]; then
    mv /etc/nginx/conf.d/10-limit-zones.conf /etc/nginx/conf.d/10-limit-zones.conf.bak.$(date +%s) || true
  fi

  if [[ -f /etc/nginx/snippets/basic-antibot.conf && ! -f /etc/nginx/snippets/basic-antibot.conf.bak ]]; then
    mv /etc/nginx/snippets/basic-antibot.conf /etc/nginx/snippets/basic-antibot.conf.bak.$(date +%s) || true
  fi

  # Thay zone cũ trong các file include (nếu còn)
  sed -i \
    -e 's/zone=perip/zone=dlh_perip/g' \
    -e 's/zone=login/zone=dlh_login/g' \
    -e 's/limit_conn_zone[[:space:]]\+\$binary_remote_addr[[:space:]]\+zone=connperip/limit_conn_zone $binary_remote_addr zone=dlh_connperip/g' \
    /etc/nginx/snippets/*.conf /etc/nginx/sites-available/*.conf /etc/nginx/sites-enabled/*.conf 2>/dev/null || true
}

main
