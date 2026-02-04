\
#!/usr/bin/env bash
set -euo pipefail

# =========================================================
# DLH-Script V2 — menu quản trị webserver
# Web root: /home/www/<domain>/public_html
# =========================================================

CONF_DIR="/etc/dlh-script"
DEFAULT_EMAIL_FILE="${CONF_DIR}/ssl_email"
ROOT_BASE_FILE="${CONF_DIR}/root_base"
ROOT_BASE_DEFAULT="/home/www"

NGINX_SITES_AVAILABLE="/etc/nginx/sites-available"
NGINX_SITES_ENABLED="/etc/nginx/sites-enabled"
SNIPPET_ANTIBOT="/etc/nginx/snippets/dlh-basic-antibot.conf"

mkdir -p "${CONF_DIR}"
mkdir -p "${NGINX_SITES_AVAILABLE}" "${NGINX_SITES_ENABLED}"

read_tty() {
  local prompt="$1" default="${2:-}"
  local ans
  if [[ -n "$default" ]]; then
    read -r -p "${prompt} [${default}]: " ans </dev/tty || true
    echo "${ans:-$default}"
  else
    read -r -p "${prompt}" ans </dev/tty || true
    echo "${ans}"
  fi
}

press_enter() { read -r -p "Nhấn Enter để tiếp tục..." _ </dev/tty || true; }

root_base_get() {
  cat "${ROOT_BASE_FILE}" 2>/dev/null || echo "${ROOT_BASE_DEFAULT}"
}

root_base_set() {
  local rb
  rb="$(read_tty "Nhập thư mục web gốc" "$(root_base_get)")"
  [[ -n "$rb" ]] || rb="${ROOT_BASE_DEFAULT}"
  mkdir -p "$rb"
  echo "$rb" > "${ROOT_BASE_FILE}"
  echo "[OK] ROOT_BASE = $rb"
}

email_get() { cat "${DEFAULT_EMAIL_FILE}" 2>/dev/null || true; }
email_set() {
  local em
  em="$(read_tty "Nhập email SSL mặc định" "$(email_get)")"
  if [[ -z "$em" ]]; then
    echo "[ERR] Email trống."
  else
    echo "$em" > "${DEFAULT_EMAIL_FILE}"
    echo "[OK] Đã lưu email SSL mặc định: $em"
  fi
}

ensure_pkgs() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y nginx certbot python3-certbot-nginx dnsutils || true
}

dns_has_www() {
  local domain="$1"
  # Use public DNS to avoid /etc/hosts / local resolver tricks
  local out=""
  out="$(dig +short A "www.${domain}" @1.1.1.1 2>/dev/null; dig +short AAAA "www.${domain}" @1.1.1.1 2>/dev/null; dig +short A "www.${domain}" @8.8.8.8 2>/dev/null; dig +short AAAA "www.${domain}" @8.8.8.8 2>/dev/null)"
  [[ -n "$(echo "$out" | sed '/^\s*$/d' | head -n 1)" ]]
}

domain_exists() {
  [[ -f "${NGINX_SITES_AVAILABLE}/${1}.conf" ]] || [[ -d "$(root_base_get)/${1}" ]]
}

list_domains() {
  echo "---- Domain đã thêm (vhost) ----"
  if ls -1 "${NGINX_SITES_AVAILABLE}"/*.conf >/dev/null 2>&1; then
    ls -1 "${NGINX_SITES_AVAILABLE}"/*.conf | sed 's#.*/##' | sed 's/\.conf$//' | sort
  else
    echo "(chưa có)"
  fi
}

list_ssl_domains() {
  echo "---- Domain đang có SSL (Let's Encrypt) ----"
  if [[ -d /etc/letsencrypt/live ]]; then
    find /etc/letsencrypt/live -maxdepth 1 -mindepth 1 -type d -printf "%f\n" | sort || true
  else
    echo "(chưa có)"
  fi
}

add_domain() {
  local domain rb site_dir
  rb="$(root_base_get)"
  domain="$(read_tty "Nhập tên miền (vd: example.com): " "")"
  [[ -n "$domain" ]] || { echo "[HỦY]"; return; }

  if domain_exists "$domain"; then
    echo "[CẢNH BÁO] Domain đã tồn tại: $domain"
    return
  fi

  site_dir="${rb}/${domain}/public_html"
  mkdir -p "${site_dir}"
  chown -R www-data:www-data "${rb}/${domain}" || true

  # Default vhost HTTP
  cat > "${NGINX_SITES_AVAILABLE}/${domain}.conf" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${domain};

  root ${site_dir};
  index index.php index.html;

  include ${SNIPPET_ANTIBOT};

  location / {
    try_files \$uri \$uri/ /index.php?\$args;
  }

  location ~ \.php$ {
    include snippets/fastcgi-php.conf;
    fastcgi_pass unix:/run/php/php-fpm.sock;
  }

  location ~* \.(jpg|jpeg|png|gif|css|js|svg|ico|woff2?)$ {
    expires 30d;
    access_log off;
  }
}
EOF

  # Resolve php-fpm socket (best effort)
  local sock
  sock="$(ls /run/php/php*-fpm.sock 2>/dev/null | head -n 1 || true)"
  if [[ -n "$sock" ]]; then
    sed -i "s#fastcgi_pass unix:/run/php/php-fpm.sock;#fastcgi_pass unix:${sock};#g" "${NGINX_SITES_AVAILABLE}/${domain}.conf"
  fi

  ln -s "${NGINX_SITES_AVAILABLE}/${domain}.conf" "${NGINX_SITES_ENABLED}/${domain}.conf" 2>/dev/null || true

  nginx -t
  systemctl reload nginx
  echo "[OK] Đã thêm domain + vhost: ${domain}"
  echo "[OK] Webroot: ${site_dir}"
}

pick_domain_for_ssl() {
  local domain
  echo
  list_domains
  echo
  domain="$(read_tty "Cài SSL cho domain nào (nhập số hoặc gõ domain, Enter để hủy): " "")"
  echo "$domain"
}

install_ssl() {
  ensure_pkgs

  local domain email rb want_www
  domain="$(read_tty "Nhập tên miền để cài SSL (vd: example.com): " "")"
  [[ -n "$domain" ]] || { echo "[HỦY]"; return; }

  # If user types number, map to list
  if [[ "$domain" =~ ^[0-9]+$ ]]; then
    local idx="$domain" i=0
    domain=""
    while IFS= read -r d; do
      i=$((i+1))
      if [[ "$i" -eq "$idx" ]]; then domain="$d"; break; fi
    done < <(ls -1 "${NGINX_SITES_AVAILABLE}"/*.conf 2>/dev/null | sed 's#.*/##' | sed 's/\.conf$//' | sort)
    [[ -n "$domain" ]] || { echo "[ERR] Số không hợp lệ."; return; }
  fi

  email="$(email_get)"
  if [[ -z "$email" ]]; then
    email="$(read_tty "Nhập email SSL (Let's Encrypt): " "")"
    [[ -n "$email" ]] || { echo "[ERR] Cần email để xin SSL."; return; }
    echo "$email" > "${DEFAULT_EMAIL_FILE}"
    echo "[OK] Đã lưu email SSL mặc định: $email"
  else
    echo "[OK] Dùng email SSL mặc định: $email"
  fi

  local domains_args
  domains_args=(-d "$domain")

  # AUTO bỏ www nếu DNS thiếu (chuẩn). Nếu có www thì thêm luôn.
  if dns_has_www "$domain"; then
    echo "[OK] DNS có www.${domain} -> xin SSL kèm www"
    domains_args+=(-d "www.${domain}")
  else
    echo "[OK] DNS KHÔNG có www.${domain} -> bỏ www"
  fi

  # Ensure vhost exists
  if [[ ! -f "${NGINX_SITES_ENABLED}/${domain}.conf" ]] && [[ -f "${NGINX_SITES_AVAILABLE}/${domain}.conf" ]]; then
    ln -s "${NGINX_SITES_AVAILABLE}/${domain}.conf" "${NGINX_SITES_ENABLED}/${domain}.conf" 2>/dev/null || true
  fi

  nginx -t

  # Non-interactive + auto expand to avoid certbot prompt
  certbot --nginx \
    --non-interactive --agree-tos --email "$email" \
    --expand --redirect --hsts --staple-ocsp \
    "${domains_args[@]}"

  systemctl reload nginx
  echo "[OK] Đã cài SSL cho: ${domains_args[*]}"
}

delete_domain() {
  local domain rb dbname
  rb="$(root_base_get)"
  domain="$(read_tty "Nhập domain cần XÓA (vd: example.com): " "")"
  [[ -n "$domain" ]] || { echo "[HỦY]"; return; }

  echo "[CẢNH BÁO] Sẽ xóa vhost + thư mục web + (tuỳ chọn) database."
  local ok
  ok="$(read_tty "Gõ YES để xác nhận: " "")"
  [[ "$ok" == "YES" ]] || { echo "[HỦY]"; return; }

  rm -f "${NGINX_SITES_ENABLED}/${domain}.conf" || true
  rm -f "${NGINX_SITES_AVAILABLE}/${domain}.conf" || true

  # Remove site directory
  rm -rf "${rb}/${domain}" || true

  # Remove cert if exists (best-effort)
  if [[ -d "/etc/letsencrypt/live/${domain}" ]]; then
    certbot delete --cert-name "${domain}" --non-interactive || true
  fi

  # Optional DB drop
  dbname="$(read_tty "Nhập tên database để xóa (Enter bỏ qua): " "")"
  if [[ -n "$dbname" ]]; then
    if command -v mysql >/dev/null 2>&1; then
      mysql -e "DROP DATABASE IF EXISTS \`${dbname}\`;" || true
      echo "[OK] Đã xóa DB: $dbname (nếu tồn tại)"
    else
      echo "[WARN] Không có mysql client trên máy."
    fi
  fi

  nginx -t
  systemctl reload nginx
  echo "[OK] Đã xóa domain: $domain"
}

nginx_tools() {
  echo "1) nginx -t"
  echo "2) systemctl status nginx"
  echo "3) Reload nginx"
  echo "0) Quay lại"
  local c
  c="$(read_tty "Chọn: " "")"
  case "$c" in
    1) nginx -t; press_enter;;
    2) systemctl status nginx --no-pager; press_enter;;
    3) systemctl reload nginx; echo "[OK] Reloaded"; press_enter;;
    *) ;;
  esac
}

main_menu() {
  while true; do
    clear || true
    echo "DLH-Script V2"
    echo "Menu webserver cơ bản (Nginx/PHP/SSL) — /home/www/<domain>/public_html"
    echo "------------------------------------------------------------"
    echo "[TÊN MIỀN / SSL]"
    echo "1) Thêm tên miền (tạo vhost + thư mục web)"
    echo "2) Cài SSL (Let's Encrypt — tự bỏ www nếu DNS thiếu)"
    echo "3) Xóa tên miền (+ thư mục web + tùy chọn DB)"
    echo "4) Thiết lập email SSL mặc định"
    echo "5) Danh sách domain đã thêm"
    echo "6) Danh sách domain đang dùng SSL"
    echo
    echo "[HỆ THỐNG / CÔNG CỤ]"
    echo "7) Công cụ Nginx (test/status/reload)"
    echo "8) Đổi ROOT_BASE (mặc định /home/www)"
    echo
    echo "9) Cập nhật script (dlh-update)"
    echo "0) Thoát"
    echo "------------------------------------------------------------"
    local c
    c="$(read_tty "Chọn: " "")"
    case "$c" in
      1) add_domain; press_enter;;
      2) install_ssl; press_enter;;
      3) delete_domain; press_enter;;
      4) email_set; press_enter;;
      5) list_domains; press_enter;;
      6) list_ssl_domains; press_enter;;
      7) nginx_tools;;
      8) root_base_set; press_enter;;
      9) dlh-update || true; press_enter;;
      0) exit 0;;
      *) ;;
    esac
  done
}

main_menu
