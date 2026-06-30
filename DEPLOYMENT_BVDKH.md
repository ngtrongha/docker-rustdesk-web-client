# Triển khai RustDesk Web Client cô lập

Tài liệu này là quy trình production cho hạ tầng BVDKH. `docker-compose.yml` chỉ dùng để thử local; production luôn dùng `deploy_offline.ps1` và `docker-compose.web.yml`.

## Phạm vi an toàn

- Chỉ tạo/recreate container `rustdesk-web-client`, project Compose `rustdesk-web`.
- Chỉ bind `172.16.3.28:22180`; không publish `5000`, `21118` hoặc `21119`.
- Dùng network external đang được cả `rustdesk-hbbs`, `rustdesk-hbbr` và `rustdesk-api` sử dụng.
- Không sửa `unified_deploy`, Nginx dùng chung, Serverpod, PostgreSQL, Redis, MinIO hoặc Janus.
- Không restart `rustdesk-api` hay `rustdesk-hbbr`.
- `rustdesk-hbbs` chỉ được recreate một lần khi chủ động chạy `-Initialize`.

## Chuẩn bị và deploy offline

Máy local cần Docker Desktop đang chạy, Git, OpenSSH (`ssh`, `scp`) và có Internet để build. Private server chỉ cần Docker/Compose; quá trình remote không clone Git và không tải dependency.

Trước lần deploy đầu tiên, commit toàn bộ source của repo này. Script từ chối working tree chưa commit để tag `local-rustdesk-web-client:<git-short-sha>` luôn đại diện cho đúng một bộ source.

```powershell
Set-Location C:\Work\BVDKH\rustdesk-deploy\docker-rustdesk-web-client

# Lần đầu: deploy Web Client và thay riêng command của hbbs.
.\deploy_offline.ps1 -Initialize

# Các lần nâng cấp Web Client sau: không chạm hbbs.
.\deploy_offline.ps1
```

Với `-Initialize`, sau khi `hbbs` chạy ổn định, script dừng ở bước xác nhận. Hãy mở một RustDesk client trong LAN và kiểm tra client đăng ký lại được, rồi nhập chính xác `YES`. Câu trả lời khác sẽ tự khôi phục Compose cũ và recreate riêng `hbbs`.

Không dùng `-ConfirmClientRegistration` trừ khi việc đăng ký LAN đã được xác nhận bằng một quy trình tự động bên ngoài.

## Luồng trong private server

```text
Cloudflare connector
  -> http://172.16.3.28:22180
     -> rustdesk-web-client:80
        /api/*, /lic/* -> rustdesk-api:8080
        /ws/id         -> rustdesk-hbbs:21118
        /ws/relay      -> rustdesk-hbbr:21119
        /              -> Flutter Web static files
```

`runtime-config.js` được tạo lại khi container start, chứa hostname, URL API và public key. Không có mật khẩu điều khiển trong image, Compose hoặc runtime config.

Giới hạn firewall của private server để chỉ private IP của public server được gọi `172.16.3.28:22180`. Cách đặt rule phụ thuộc firewall đang dùng; phải chụp và kiểm tra rule hiện tại trước khi thay đổi. Không mở port này trên router/Internet.

## Cloudflare Tunnel: cập nhật qua connector canary

Các biến dưới đây là placeholder và phải được thay bằng đường dẫn/tunnel thật trên public server:

```bash
MAIN_CONFIG=/etc/cloudflared/config.yml
CANARY_CONFIG=/etc/cloudflared/config.canary.yml
TUNNEL_UUID=<UUID_CUA_TUNNEL_HIEN_TAI>
```

### 1. Ghi baseline

Lưu danh sách hostname hiện tại và đo liên tục mã HTTP/độ trễ từ một máy ngoài mạng. Không tiếp tục nếu đã có timeout hoặc 5xx trước thay đổi.

### 2. Tạo và validate config canary

Sao chép nguyên config hiện tại, sau đó chèn rule này **trước** catch-all cuối cùng:

```yaml
ingress:
  - hostname: remote-connect.bvkhanhhoa.cloud
    service: http://172.16.3.28:22180

  # Giữ nguyên toàn bộ rule hiện tại ở đây.

  - service: http_status:404
```

Validate đúng file và kiểm tra rule match:

```bash
cloudflared --config "$CANARY_CONFIG" tunnel ingress validate
cloudflared --config "$CANARY_CONFIG" tunnel ingress rule https://remote-connect.bvkhanhhoa.cloud
```

### 3. Chạy connector canary

Chạy thêm một process với cùng tunnel UUID/credential nhưng dùng config canary, ví dụ bằng một transient service riêng:

```bash
sudo systemd-run \
  --unit=cloudflared-canary \
  --property=Restart=always \
  cloudflared --config "$CANARY_CONFIG" tunnel run "$TUNNEL_UUID"

cloudflared tunnel info "$TUNNEL_UUID"
```

Chỉ tiếp tục khi thấy hai connector ID và baseline của tất cả hostname cũ vẫn sạch.

### 4. Thay config chính atomically

```bash
sudo install -m 600 "$CANARY_CONFIG" "${MAIN_CONFIG}.next"
sudo mv "${MAIN_CONFIG}.next" "$MAIN_CONFIG"
sudo systemctl restart cloudflared
cloudflared tunnel info "$TUNNEL_UUID"
```

Canary phải tiếp tục chạy trong suốt lúc connector chính restart. Khi connector chính đã healthy và baseline hostname cũ vẫn ổn, mới tạo DNS/public hostname `remote-connect.bvkhanhhoa.cloud` trỏ tới `<UUID>.cfargotunnel.com`.

Sau khi Web UI, API và hai WebSocket đều qua kiểm tra, dừng canary:

```bash
sudo systemctl stop cloudflared-canary.service
sudo systemctl reset-failed cloudflared-canary.service
```

Replica tránh gián đoạn nhận request mới khi đổi config. Tuy nhiên, khi connector cũ bị restart, WebSocket/TCP lâu dài đang đi qua chính connector đó có thể bị ngắt và phải reconnect; vì vậy không thực hiện đổi connector giữa một phiên điều khiển quan trọng.

## Cloudflare Access và cache/WAF

- Tạo Access application chỉ cho `remote-connect.bvkhanhhoa.cloud`, yêu cầu MFA và giới hạn đúng nhóm người vận hành.
- Tạo Cache Rule cho hostname này với hành động bypass cache. Runtime cũng đã gửi `no-store` riêng cho `runtime-config.js`.
- Với `/ws/*`, bypass cache và bỏ Managed Challenge/custom challenge ở bước HTTP Upgrade. Không bypass Access; cookie/token Access của phiên đã xác thực vẫn phải được kiểm tra.
- Bật WebSockets cho zone. Không dùng Worker/redirect làm thay đổi đường dẫn `/ws/id` hoặc `/ws/relay`.

## Kiểm tra nghiệm thu

```bash
curl -fsS http://172.16.3.28:22180/healthz
curl -fsS https://remote-connect.bvkhanhhoa.cloud/healthz
curl -fsS https://remote-connect.bvkhanhhoa.cloud/runtime-config.js
```

Kiểm tra WebSocket bằng công cụ có thể gửi header Upgrade (ví dụ `websocat` hoặc DevTools); cả `/ws/id` và `/ws/relay` phải chuyển sang kết nối WebSocket, không trả HTML/redirect challenge.

Sau đó dùng một máy LAN test bàn phím, chuột, clipboard, đa màn hình, reconnect và giữ phiên tối thiểu 60 phút. Đồng thời xác nhận:

- Host không listen public trên `5000`, `21118`, `21119`.
- `22180` chỉ chấp nhận public server theo firewall.
- Các hostname cũ không timeout/5xx trong toàn bộ lần chuyển connector.
- `docker ps` cho thấy `rustdesk-api`, `rustdesk-hbbr` và các project khác không có thời điểm start/recreate mới.

## Rollback

Web Client tự rollback khi container/HTTP healthcheck thất bại. Nó giữ `.env.web.rollback`, `docker-compose.web.yml.rollback` và một image trước đó tại:

```text
/home/app-ubuntu/serverpod_app/rustdesk-deploy/web-client
```

Nếu lỗi chỉ xuất hiện sau nghiệm thu, thay hai file active bằng bản `.rollback`, rồi chạy duy nhất:

```bash
docker compose -p rustdesk-web \
  --env-file .env.web \
  -f docker-compose.web.yml \
  up -d --no-deps rustdesk-web
```

Để rollback public route, khôi phục config Tunnel trước đó bằng connector canary, kiểm tra hostname cũ, rồi xóa DNS `remote-connect`. Không restart Nginx dùng chung hay project khác.

## Tài liệu Cloudflare đối chiếu

- [Cấu hình ingress và quy trình cập nhật bằng replica](https://developers.cloudflare.com/tunnel/advanced/local-management/configuration-file/)
- [Chạy nhiều connector/replica cho cùng Tunnel](https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/deploy-replicas/)
- [WebSockets qua Cloudflare và lưu ý WAF](https://developers.cloudflare.com/network/websockets/)
