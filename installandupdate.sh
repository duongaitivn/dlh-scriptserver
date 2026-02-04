#!/usr/bin/env bash
set -euo pipefail
DEFAULT_INSTALL_URL="https://raw.githubusercontent.com/duongaitivn/dlh-scriptserver/main/dlh-script.sh"
CONFIG_DIR="/etc/dlh-script"
CONFIG_FILE="${CONFIG_DIR}/config.env"
BIN="/usr/local/bin/dlh-script"
LINK_BIN="/usr/local/bin/dlh"
say(){ echo -e "$*"; }
die(){ echo -e "[LỖI] $*" >&2; exit 1; }
need_root(){ [[ "${EUID:-$(id -u)}" -eq 0 ]] || die "Hãy chạy: sudo bash $0"; }
ensure_dirs(){ mkdir -p "$CONFIG_DIR"; touch "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE"; }
get_cfg(){ local k="$1"; [[ -f "$CONFIG_FILE" ]] && source "$CONFIG_FILE" || true; eval "echo \"\${$k:-}\"" ; }
set_cfg(){ local k="$1" v="$2"; mkdir -p "$CONFIG_DIR"; touch "$CONFIG_FILE"; chmod 600 "$CONFIG_FILE";
  if grep -qE "^${k}=" "$CONFIG_FILE"; then sed -i "s|^${k}=.*|${k}=$(printf %q "$v")|g" "$CONFIG_FILE";
  else printf "%s=%q\n" "$k" "$v" >> "$CONFIG_FILE"; fi; }
force_ipv4_apt(){ mkdir -p /etc/apt/apt.conf.d; cat >/etc/apt/apt.conf.d/99force-ipv4 <<'EOF'
Acquire::ForceIPv4 "true";
EOF
}
curl4(){ curl -4 -fL --connect-timeout 15 --max-time 600 -sS "$@"; }
pick_install_url(){
  local cur; cur="$(get_cfg INSTALL_URL)";
  if [[ -n "$cur" ]]; then say "[OK] INSTALL_URL hiện tại: $cur"; echo "$cur"; return; fi
  say "Nhập INSTALL_URL (Enter để dùng mặc định):"; say "  Mặc định: $DEFAULT_INSTALL_URL";
  read -r url || true; url="${url:-$DEFAULT_INSTALL_URL}";
  set_cfg INSTALL_URL "$url"; say "[OK] Đã lưu INSTALL_URL: $url"; echo "$url";
}
download_menu(){
  local url="$1"; say "[...] Tải dlh-script từ: $url";
  local tmp="/tmp/dlh-script.$RANDOM.sh"; curl4 "$url" >"$tmp" || die "Không tải được INSTALL_URL.";
  head -n 3 "$tmp" | grep -qE '^#!/usr/bin/env bash' || die "File tải về không phải bash script.";
  install -m 0755 "$tmp" "$BIN"; rm -f "$tmp"; ln -sf "$BIN" "$LINK_BIN";
  say "[OK] Đã cài: $BIN"; say "[OK] Lệnh menu: dlh";
}
main(){
  need_root; ensure_dirs; force_ipv4_apt;
  local url; url="$(pick_install_url)"; download_menu "$url";
  say; say "DLH-Script V2 — OK. Gõ: dlh"; say;
}
main "$@"
