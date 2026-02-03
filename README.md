# DLH-Script V1 — Webserver Basic (Ubuntu 24.04 / VPS 1GB)

DLH-Script V1 là bộ script cài webserver cơ bản và menu quản trị kiểu HOCVPS cho VPS nhỏ (1 Core / 1GB RAM / 30GB Disk).

## Tính năng chính (V1)
- Cài **Nginx + PHP-FPM 8.3** + extensions phổ biến cho WordPress
- Tối ưu PHP-FPM cho VPS 1GB (ondemand, giới hạn children/requests)
- Bảo mật cơ bản:
  - UFW mở cổng: 22/80/443
  - Fail2ban (SSH)
- Tạo swap 2GB + swappiness hợp lý
- Nginx hardening:
  - server_tokens off
  - chặn file nhạy cảm (.env, .git, composer.*, package.*…)
  - rate limit / limit conn nhẹ phù hợp 1GB
  - gzip: tự phát hiện nếu đã bật thì không tạo trùng (tránh duplicate)
- Logrotate cho Nginx logs
- Tạo menu `dlh` (Việt hoá):
  - Thêm tên miền (vhost + webroot)
  - Cài SSL Let’s Encrypt + HTTP/2 + auto renew
    - AUTO: nếu DNS thiếu `www` thì tự bỏ `www` (không fail)
  - Tiện ích WordPress: WP-CLI / tải WordPress (vi) / sửa quyền
- Update 1 lệnh: `webserver-update`

## Yêu cầu
- Ubuntu 24.04
- Quyền sudo/root
- VPS tối thiểu: 1 Core / 1GB RAM / 25–30GB Disk

## Cài đặt (Install)
Chạy 1 lệnh (thay đúng URL repo của bạn):

```bash
curl -fsSL https://raw.githubusercontent.com/duongaitivn/dlh-scriptserver/main/webserver.sh | sudo INSTALL_URL="https://raw.githubusercontent.com/duongaitivn/dlh-scriptserver/main/webserver.sh" bash
