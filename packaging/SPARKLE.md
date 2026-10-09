# Đánh giá tích hợp Sparkle 2 (auto-update)

**Kết luận đợt này: CHƯA tích hợp** — cần 2 thứ nằm ngoài repo:
1. **EdDSA key pair** (ký appcast) — private key phải do chủ dự án tạo và giữ
   (`generate_keys` của Sparkle), tuyệt đối không commit.
2. **Hosting appcast.xml** — GitHub Releases dùng được (đính kèm appcast vào
   release hoặc GitHub Pages).

## Việc cần làm khi quyết định tích hợp (ước ~1 buổi)
- Thêm SPM dependency `sparkle-project/Sparkle` (2.x) vào target App.
- `SPUStandardUpdaterController` khởi tạo trong `MDriveHealthApp`; nút
  "Kiểm tra bản cập nhật…" trong Settings gọi `checkForUpdates()` (thay
  UpdateChecker hiện tại; giữ UpdateChecker làm fallback headless/CLI).
- Info.plist: `SUFeedURL`, `SUPublicEDKey`, giữ `ENABLE_HARDENED_RUNTIME`.
- `scripts/release.sh`: sau notarize, chạy `generate_appcast` trên thư mục
  chứa DMG → upload appcast.xml + delta lên release.
- Cân nhắc: app KHÔNG sandbox → Sparkle hoạt động đơn giản (không cần XPC
  installer phức tạp).

Hiện tại app đã có: kiểm tra update thủ công qua GitHub API + nút tải DMG
(SettingsView), đủ dùng tới khi lượng user tăng.
