#!/usr/bin/env bash
set -euo pipefail
VERSION="DLH-Script V2"
CONFIG_DIR="/etc/dlh-script"
CONFIG_FILE="${CONFIG_DIR}/config.env"
STATE_DIR="/var/lib/dlh-script"
ROOT_BASE_DEFAULT="/home/www"
NGINX_SNIPPETS_DIR="/etc/nginx/snippets"
CONF_DIR="/etc/nginx/conf.d"
SITES_AVAIL="/etc/nginx/sites-available"
SITES_ENA="/etc/nginx/sites-enabled"
say(){ echo -e "$*"; }
warn(){ echo -e "[CẢNH BÁO] $*"; }
ok(){ echo -e "[OK] $*"; }
die(){ echo -e "[LỖI] $*" >&2; exit 1; }
need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Hãy chạy: sudo dlh"; }
ensure_dirs(){ mkdir -p "$CONFIG_DIR" "$STATE_DIR" "$NGINX_SNIPPETS_DIR" "$CONF_DIR" "$SITES_AVAIL" "$SITES_ENA"; touch "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"; }
load_cfg(){ [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" || true; ROOT_BASE="${ROOT_BASE:-$ROOT_BASE_DEFAULT}"; DEFAULT_SSL_EMAIL="${DEFAULT_SSL_EMAIL:-}"; }
set_cfg(){ local k="$1" v="$2"; if grep -qE "^${k}=" "$CONFIG_FILE"; then sed -i "s|^${k}=.*|${k}=$(printf %q "$v")|g" "$CONFIG_FILE"; else printf "%s=%q\n" "$k" "$v" >> "$CONFIG_FILE"; fi; }
force_ipv4_apt(){ mkdir -p /etc/apt/apt.conf.d; cat >/etc/apt/apt.conf.d/99force-ipv4 <<'EOF'
Acquire::ForceIPv4 "true";
EOF
}
curl4(){ curl -4 -fL --connect-timeout 15 --max-time 600 -sS "$@"; }
apt_update(){ export DEBIAN_FRONTEND=noninteractive; force_ipv4_apt; apt-get -y update; }
apt_install(){ export DEBIAN_FRONTEND=noninteractive; apt-get -y install "$@"; }
nginx_test(){ nginx -t; }
nginx_reload(){ systemctl reload nginx || systemctl restart nginx; }
domain_valid(){ [[ "$1" =~ ^([a-zA-Z0-9-]+\.)+[a-zA-Z]{2,}$ ]]; }
domain_paths(){ local d="$1"; echo "${ROOT_BASE}/${d}|${ROOT_BASE}/${d}/public_html"; }
site_exists(){ local d="$1"; [[ -f "${SITES_AVAIL}/${d}.conf" || -L "${SITES_ENA}/${d}.conf" || -d "${ROOT_BASE}/${d}" ]]; }
list_domains(){ ls -1 "${SITES_AVAIL}" 2>/dev/null | sed -n 's/\.conf$//p' | sort -u; }
list_ssl_domains(){ command -v certbot >/dev/null 2>&1 || { say "(Chưa cài certbot)"; return; }; certbot certificates 2>/dev/null | awk '/^Certificate Name: /{n=$3}/^Domains: /{$1="";sub(/^ /,"");print n" -> "$0}'; }
dns_has_any_record(){ local h="$1"; command -v dig >/dev/null 2>&1 && { [[ -n "$(dig +time=2 +tries=1 +short A "$h" @1.1.1.1 | head -n1)" || -n "$(dig +time=2 +tries=1 +short AAAA "$h" @1.1.1.1 | head -n1)" ]]; return; }; getent ahosts "$h" >/dev/null 2>&1; }
cleanup_old_conf_collisions(){
  local keep1="${CONF_DIR}/00-dlh-security.conf" keep2="${CONF_DIR}/01-dlh-gzip.conf" keep3="${CONF_DIR}/10-dlh-limit-zones.conf"
  for f in "${CONF_DIR}"/00-*.conf "${CONF_DIR}"/01-*.conf "${CONF_DIR}"/10-*.conf; do
    [[ -e "$f" ]] || continue
    if [[ "$f" != "$keep1" && "$f" != "$keep2" && "$f" != "$keep3" ]]; then
      if grep -qE '^\s*(server_tokens|gzip\s+on;|limit_req_zone|limit_conn_zone)\b' "$f"; then
        mv -f "$f" "${f}.bak.$(date +%s)" || true
      fi
    fi
  done
}
gzip_already_enabled(){ grep -RInE '^\s*gzip\s+on\s*;' /etc/nginx/nginx.conf /etc/nginx/conf.d /etc/nginx/sites-enabled 2>/dev/null | head -n1 | grep -q .; }
write_security_conf(){ cat >"${CONF_DIR}/00-dlh-security.conf" <<'EOF'
server_tokens off;
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
add_header Referrer-Policy "strict-origin-when-cross-origin" always;
add_header X-XSS-Protection "1; mode=block" always;
EOF
}
write_gzip_conf(){ if gzip_already_enabled; then ok "Đã có gzip on -> bỏ qua"; rm -f "${CONF_DIR}/01-dlh-gzip.conf" 2>/dev/null || true; return; fi; cat >"${CONF_DIR}/01-dlh-gzip.conf" <<'EOF'
gzip on;
gzip_vary on;
gzip_proxied any;
gzip_comp_level 5;
gzip_min_length 1024;
gzip_types text/plain text/css application/json application/javascript text/xml application/xml application/xml+rss text/javascript image/svg+xml;
EOF
}
write_limit_zones_conf(){ cat >"${CONF_DIR}/10-dlh-limit-zones.conf" <<'EOF'
limit_req_zone  $binary_remote_addr zone=dlh_perip:10m  rate=5r/s;
limit_req_zone  $binary_remote_addr zone=dlh_login:10m rate=1r/s;
limit_conn_zone $binary_remote_addr zone=dlh_connperip:10m;
EOF
}
write_antibot_snippet(){ cat >"${NGINX_SNIPPETS_DIR}/dlh-basic-antibot.conf" <<'EOF'
limit_conn dlh_connperip 20;
limit_req zone=dlh_perip burst=40 nodelay;
location ~* ^/(wp-login\.php|wp-admin/|xmlrpc\.php)$ { limit_req zone=dlh_login burst=10 nodelay; }
EOF
}
patch_default_site(){ local f="${SITES_ENA}/0.conf"; [[ -f "$f" ]] || return 0; sed -i 's|/etc/nginx/snippets/basic-antibot\.conf|/etc/nginx/snippets/dlh-basic-antibot.conf|g' "$f" || true; }
apply_nginx_basics(){ ok "Fix Nginx duplicates/zone/snippet"; cleanup_old_conf_collisions; write_security_conf; write_gzip_conf; write_limit_zones_conf; write_antibot_snippet; patch_default_site; nginx_test; nginx_reload; ok "Nginx OK"; }
install_stack(){ apt_update; apt_install nginx; apt_install php-fpm php-cli php-mysql php-curl php-mbstring php-xml php-zip php-gd php-intl; systemctl enable --now nginx; systemctl enable --now php8.3-fpm || true; apply_nginx_basics; }
install_ssl_tools(){ apt_update; apt_install certbot python3-certbot-nginx; apt_install dnsutils || true; systemctl enable --now nginx; }
write_vhost_http(){
  local d="$1"; local p; p="$(domain_paths "$d")"; local site_dir="${p%%|*}" web_root="${p##*|}"
  mkdir -p "$web_root" "${site_dir}/logs"
  [[ -f "${web_root}/index.html" || -f "${web_root}/index.php" ]] || echo "<h1>$d</h1><p>web_root: $web_root</p>" >"${web_root}/index.html"
  cat >"${SITES_AVAIL}/${d}.conf" <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name ${d};
  root ${web_root};
  index index.php index.html;
  access_log ${site_dir}/logs/access.log;
  error_log  ${site_dir}/logs/error.log;
  include ${NGINX_SNIPPETS_DIR}/dlh-basic-antibot.conf;
  location / { try_files \$uri \$uri/ /index.php?\$args; }
  location ~ \\.php\$ { include snippets/fastcgi-php.conf; fastcgi_pass unix:/run/php/php8.3-fpm.sock; }
}
EOF
  ln -sf "${SITES_AVAIL}/${d}.conf" "${SITES_ENA}/${d}.conf"
}
add_domain(){ read -r -p "Nhập tên miền: " d || true; d="${d:-}"; [[ -n "$d" ]] || return; d="$(echo "$d"|tr -d ' ')"; domain_valid "$d" || die "Domain không hợp lệ"; site_exists "$d" && { warn "Đã tồn tại: $d"; return; }; write_vhost_http "$d"; nginx_test; nginx_reload; ok "Đã thêm: $d (web_root: ${ROOT_BASE}/${d}/public_html)"; }
set_default_ssl_email(){ read -r -p "Nhập email SSL mặc định: " em || true; em="${em:-}"; [[ -n "$em" ]] || return; set_cfg DEFAULT_SSL_EMAIL "$em"; ok "Đã lưu: $em"; }
pick_domain_for_ssl(){
  local ds; ds="$(list_domains||true)"; say "Chọn domain cài SSL (nhập số hoặc gõ domain, Enter để hủy):"
  if [[ -n "$ds" ]]; then local i=1; while IFS= read -r x; do say "  $i) $x"; i=$((i+1)); done <<<"$ds"; fi
  read -r pick || true; [[ -n "$pick" ]] || { echo ""; return; }
  [[ "$pick" =~ ^[0-9]+$ ]] && { echo "$ds" | sed -n "${pick}p"; return; }
  echo "$pick"
}
certbot_try(){ local d="$1" em="$2" want_www="$3"; local args=(-n --agree-tos --redirect --hsts --staple-ocsp --email "$em"); [[ "$want_www" == "1" ]] && args+=(-d "$d" -d "www.$d") || args+=(-d "$d"); certbot --nginx "${args[@]}" 2>&1; }
install_ssl(){
  local d; d="$(pick_domain_for_ssl)"; [[ -n "$d" ]] || return; domain_valid "$d" || die "Domain không hợp lệ"
  install_ssl_tools
  local em="${DEFAULT_SSL_EMAIL:-}"
  if [[ -z "$em" ]]; then read -r -p "Nhập email SSL: " em || true; [[ -n "${em:-}" ]] || die "Thiếu email"; set_cfg DEFAULT_SSL_EMAIL "$em"; fi
  [[ -f "${SITES_AVAIL}/${d}.conf" ]] || { warn "Chưa có vhost -> tạo tạm"; write_vhost_http "$d"; nginx_test; nginx_reload; }
  local want_www=0; dns_has_any_record "www.$d" && { ok "DNS có www -> thử kèm www"; want_www=1; } || ok "DNS thiếu www -> bỏ www"
  set +e; local out; out="$(certbot_try "$d" "$em" "$want_www")"; local rc=$?; set -e
  if [[ $rc -eq 0 ]]; then ok "SSL OK: $d"; nginx_test; nginx_reload; return; fi
  if [[ "$want_www" == "1" ]] && echo "$out" | grep -qiE 'NXDOMAIN.*www\.|No valid IP addresses found for www\.|DNS problem:.*www\.'; then
    warn "www DNS lỗi -> xin lại không kèm www"
    set +e; out="$(certbot_try "$d" "$em" "0")"; rc=$?; set -e
    [[ $rc -eq 0 ]] && { ok "SSL OK (bỏ www): $d"; nginx_test; nginx_reload; return; }
  fi
  warn "SSL thất bại (tail log):"; echo "$out" | tail -n 40 || true
}
delete_domain(){
  local ds; ds="$(list_domains||true)"; [[ -n "$ds" ]] || { warn "Chưa có domain"; return; }
  say "Danh sách domain:"; local i=1; while IFS= read -r x; do say "  $i) $x"; i=$((i+1)); done <<<"$ds"
  read -r -p "Nhập số hoặc domain để xóa (Enter hủy): " pick || true; [[ -n "$pick" ]] || return
  local d="$pick"; [[ "$pick" =~ ^[0-9]+$ ]] && d="$(echo "$ds"|sed -n "${pick}p")"
  read -r -p "XÁC NHẬN xóa '$d' (gõ: xoa): " c || true; [[ "$c" == "xoa" ]] || { warn "Hủy"; return; }
  rm -f "${SITES_ENA}/${d}.conf" "${SITES_AVAIL}/${d}.conf" 2>/dev/null || true
  rm -rf "${ROOT_BASE:?}/${d}" 2>/dev/null || true
  command -v certbot >/dev/null 2>&1 && certbot delete --cert-name "$d" -n >/dev/null 2>&1 || true
  nginx_test || true; nginx_reload || true; ok "Đã xóa: $d"
}
nginx_tools(){ while true; do clear; say "[$VERSION] — NGINX"; say "1) nginx -t"; say "2) reload"; say "3) fix duplicates/zone/snippet"; say "0) back"; read -r -p "Chọn: " c || true; case "${c:-}" in 1) nginx_test; read -r -p "Enter..." _;; 2) nginx_reload; ok "OK"; read -r -p "Enter..." _;; 3) apply_nginx_basics; read -r -p "Enter..." _;; 0) return;; esac; done; }
system_menu(){ while true; do clear; say "$VERSION — HỆ THỐNG"; say "1) Cài Nginx+PHP (kèm fix)"; say "2) Công cụ Nginx"; say "3) DS domain"; say "4) DS SSL"; say "5) Set ROOT_BASE (hiện: ${ROOT_BASE})"; say "6) Set email SSL"; say "0) back"; read -r -p "Chọn: " c || true; case "${c:-}" in 1) install_stack; read -r -p "Enter..." _;; 2) nginx_tools;; 3) list_domains; read -r -p "Enter..." _;; 4) list_ssl_domains; read -r -p "Enter..." _;; 5) read -r -p "ROOT_BASE mới (Enter hủy): " rb || true; [[ -n "${rb:-}" ]] && { ROOT_BASE="$rb"; set_cfg ROOT_BASE "$rb"; ok "Đã lưu"; }; read -r -p "Enter..." _;; 6) set_default_ssl_email; read -r -p "Enter..." _;; 0) return;; esac; done; }
domain_ssl_menu(){ while true; do clear; say "$VERSION — DOMAIN/SSL"; say "1) Thêm domain"; say "2) Cài SSL"; say "3) Xóa domain"; say "4) Set email SSL"; say "5) DS domain"; say "6) DS SSL"; say "0) back"; read -r -p "Chọn: " c || true; case "${c:-}" in 1) add_domain; read -r -p "Enter..." _;; 2) install_ssl; read -r -p "Enter..." _;; 3) delete_domain; read -r -p "Enter..." _;; 4) set_default_ssl_email; read -r -p "Enter..." _;; 5) list_domains; read -r -p "Enter..." _;; 6) list_ssl_domains; read -r -p "Enter..." _;; 0) return;; esac; done; }
main_menu(){ while true; do clear; say "$VERSION"; say "1) Hệ thống"; say "2) Tên miền/SSL"; say "0) Thoát"; read -r -p "Chọn: " c || true; case "${c:-}" in 1) system_menu;; 2) domain_ssl_menu;; 0) exit 0;; esac; done; }
main(){ need_root; ensure_dirs; load_cfg; main_menu; }
main "$@"
