# CI và các gate nghiệm thu còn lại

Workflow `.github/workflows/ci.yml` chạy cùng `scripts/ci.py` dùng để kiểm tra local. `Config/CIToolchains.json` pin version/build của Xcode, SDK, XcodeGen, OS major và kiến trúc; drift làm job thất bại. XcodeGen 2.46.0 được lấy từ release upstream với SHA256 cố định, không chạy script cài đặt upstream. Actions checkout/upload-artifact pin commit và token chỉ có quyền đọc.

| Profile | Runner | Xcode / SDK | Phạm vi |
| --- | --- | --- | --- |
| sonoma-arm64 | macos-14 | 16.2 (16C5032a) / 15.2 | Core/app contracts trên OS 14 arm64; build universal |
| sequoia-arm64 | macos-15 | 16.4 (16F6) / 15.5 | Core/app contracts trên OS 15 arm64; build universal |
| sequoia-intel | macos-15-intel | 16.4 (16F6) / 15.5 | Core/app contracts trên OS 15 Intel; build universal |
| latest-arm64 | xcode-27 | 27.0 (27A266a) / 27.0 | Contracts và DMG unsigned từ source snapshot sealed |

Runner/toolchain được đối chiếu với [GitHub runner reference](https://docs.github.com/en/actions/reference/runners/github-hosted-runners), [image macOS 14](https://github.com/actions/runner-images/blob/main/images/macos/macos-14-Readme.md), [macOS 15 arm64](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-arm64-Readme.md), [macOS 15 Intel](https://github.com/actions/runner-images/blob/main/images/macos/macos-15-Readme.md) và [image Xcode 27](https://github.com/actions/runner-images/blob/main/images/macos/xcode-27-arm64-Readme.md). Xcode 27 runner hiện là public preview. GitHub thông báo macOS 14 runner hết hỗ trợ ngày 2026-11-02; khi image bị bỏ phải cung cấp runner OS 14 thích hợp hoặc điều chỉnh phạm vi hỗ trợ có bằng chứng. Không tự đổi runner rồi coi gate OS 14 đã qua.

Mỗi lệnh CI có deadline 15 phút và phải báo lỗi nếu hết hạn; kết thúc command trong process group riêng, lưu trạng thái exit chưa xác nhận nếu vẫn chưa reap được. Gate từ chối suite Python/XCTest có zero test. Hash nguồn sau XcodeGen được đối chiếu lại khi hoàn tất; source thay đổi trong lúc test làm CI thất bại.

Mỗi job chạy packaging/toolchain regressions, Core Debug/Release/AddressSanitizer, Clang analyzer cho cả ba C source, app model suite và ba vòng stress riêng cho process/measurement/SQL và app lifecycle/monitoring/updater/login-item/history publication/TRIM metadata ownership/benchmark publication/measurement persistence. History publication kiểm tra SMART cập nhật trước khi SQL mở xong, còn revision cho biểu đồ chỉ đổi khi persistence đã kết thúc. Benchmark publication kiểm tra result đã có trước commit, revision chỉ đổi sau write attempt và retry vẫn giữ UUID khi storage lỗi. MenuBarStatus stress kiểm tra discovery/probe failure, dữ liệu cũ/ổ ngủ, unknown score, virtual filter, refresh bị chặn trước provider dispatch và phục hồi đã xác minh; không thay thế nghiệm thu status-item/popover thật. Measurement persistence kiểm tra worker với dữ liệu thử 16 KiB riêng, UUID/receipt/GC và retry giữa runner và startup recovery; lưu thành công phải giải quyết đúng lỗi ghi của UUID đó, giữ lỗi khác. TRIM fixture xác minh metadata giữ lease cho đến khi đọc xong và shutdown phải chờ; không chạy system_profiler thật. ASAN tắt leak detection (`detect_leaks=0`); đây không phải chứng nhận không có leak hoặc data race. Analyzer phải có zero diagnostics. XCTest skip được ghi trong `ci-results.json`; các phép nghiệm thu cần phần cứng/quyền/UI có trạng thái `not-run` riêng, không được coi là green do fixture qua.

Ví dụ local với đúng host/toolchain của profile, output chưa tồn tại:

```sh
python3 scripts/ci.py latest-arm64 /tmp/MDriveHealth-ci-check --package
```

Bộ test dùng dữ liệu nhỏ trong directory tạm, SQLite riêng, process con và SDK/network giả lập. Core có kiểm tra đọc RAM/Mach port của host. Workflow không benchmark/fill/eject/ra lệnh self-test firmware trên thiết bị thật, không xin quyền thông báo, không ký/notarize hoặc publish artifact ra Releases. Job latest tạo app/DMG unsigned, source ZIP, checksum và kiểm tra nội dung disk image read-only; các artifact chỉ giữ như bằng chứng CI.

F22 chỉ được nghiệm thu sau khi bốn job chạy trên **repo thật**, có URL run/log/xcresult và commit/source phù hợp; branch protection cần yêu cầu check `production-contracts`. Workspace hiện không có Git, chưa có bằng chứng job remote hoặc cấu hình branch protection. Chạy local trên OS 27 arm64 không chứng minh các profile khác.

Các gate riêng vẫn cần bản app cuối từ DMG đã ký: full UI trên minimum OS/macOS 15.7/Intel, SMART và bridge thật, HDD sleep/wake, disconnect/power loss/kernel stall, filesystem ngoài, TCC/notification, VoiceOver/keyboard/large text/contrast và soak. Nhóm26 đã tái hiện và sửa viewport sau empty→recovery trên native fixture Window, thử single/many/error/scroll với source thật. Các snapshot đó không chứng nhận mở/dismiss/hide-reinsert status-item/popover MenuBarExtra thật. Theo dõi cụ thể trong FIX_PROGRESS.md; build universal và SDK/minos metadata không thay thế các bước này.

Nhóm27 thêm bốn app tests về palette: caption/badge foreground trên nền sRGB đại diện ở bốn appearance, issue caption với nền pha10%, và production PNG renderer luôn truyền light scheme. Native cuối Anh/dark và Việt/light có4 snapshots mỗi tour;18 export PNG synthetic qua renderer production. Đây là kiểm tra palette/tint/rendering có phạm vi, không thay thế actual High Contrast settings, toàn bộ selected/accent/secondary/system-control surfaces, keyboard/VoiceOver/large text/full contrast hoặc status-item/popover thật. Các stress suite hiện có không được tăng số test do các palette tests này.

Endpoint công khai đã được GET và parser/URLSession production kiểm tra tại 2026-10-08T22:34:10Z: latest là v0.1.1, DMG tên MDriveHealth-0.1.1.dmg. Bản fix trong workspace chưa được publish; cần tăng version/build trước khi phân phối, không dùng lại tag đã phát hành.
