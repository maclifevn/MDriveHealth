# Audit mức độ sẵn sàng production của MDriveHealth

Ngày đánh giá: 08/10/2026. Phạm vi: mã nguồn trong workspace `/Volumes/DATA/Code/MDriveHealth`, ứng dụng macOS, thư viện SwiftPM, CLI, cầu nối C và IOKit, SMART và drivedb, benchmark, kiểm tra dung lượng, monitoring, SQLite, UI, quyền riêng tư, CI và đóng gói phát hành.

**Kết luận: chưa đạt mức tin cậy để phát hành production rộng rãi hoặc bắt đầu thu phí.** Có 24 phát hiện cần xử lý hoặc nghiệm thu: 9 P1, 13 P2 và 2 P3. Các vấn đề quan trọng nhất liên quan đến an toàn dữ liệu khi ghi thử và độ chính xác của kết luận sức khỏe ổ. Build thành công và test hiện có đều qua, nhưng chưa kiểm tra các tình huống này.

Việc thu phí chưa được quyết định. Ưu tiên hiện tại là ổn định sản phẩm; chưa cần thêm thanh toán, tài khoản hoặc khóa tính năng. Audit này bổ sung tài liệu, ca tái hiện và bằng chứng vào `audit/`; chưa sửa logic production. P1 là điều kiện chặn phát hành; P2 cần sửa trước khi cam kết monitoring đáng tin cậy hoặc nghiệm thu bằng bằng chứng phù hợp; P3 là cải thiện chất lượng. Số lượng phát hiện gồm cả lỗi đã tái hiện và rủi ro từ mã nguồn, không phải 24 lỗi đều đã quan sát trên phần cứng thật.

## Bằng chứng kiểm tra

Môi trường chạy: Apple Silicon arm64, macOS 27.0 build 26A428, Xcode 27.0 build 27A266a, Swift 6.4, XcodeGen 2.46.0. Deployment target của project là macOS 14.0.

| Kiểm tra | Kết quả và giới hạn |
| --- | --- |
| Core unit tests Debug | 84 test, 0 lỗi |
| Core unit tests Release | 84 test, 0 lỗi; [log](/Volumes/DATA/Code/MDriveHealth/audit/evidence/core-release-tests.log) |
| Core tests với Address Sanitizer | 84 test, 0 lỗi, không có báo cáo ASAN; [log](/Volumes/DATA/Code/MDriveHealth/audit/evidence/core-asan-tests.log) |
| App Release unsigned | Build thành công trên host hiện tại |
| App Release universal unsigned | Build thành công; Mach-O có arm64 và x86_64. Chưa chạy trên Intel |
| C static analyzer | CSMART.c và CHIDSensors.c hoàn tất, không phát hiện cảnh báo |
| Script và dữ liệu | `bash -n scripts/release.sh` qua; converter tái tạo 589 mục drivedb, tương đương dữ liệu hiện tại khi bỏ ngày sinh file |
| App smoke test | App thực sự mở; quan sát overview NVMe, RAM, sensors, history, form benchmark và capacity, trạng thái self-test không khả dụng. Không chạy ghi thử dung lượng lớn, eject hoặc self-test trên ổ thật |
| Đọc phần cứng | Đọc SMART của Apple NVMe nội bộ, RAM và sensors thành công trên máy hiện tại |
| Ca kiểm tra bổ sung | 14 test, 15 assertion thất bại theo thiết kế trên bản đang audit; [log](/Volumes/DATA/Code/MDriveHealth/audit/evidence/production-repros.log) |
| Render kết quả chia sẻ | Dùng view thật với dữ liệu giả lập `.inconclusive`, xác minh 0 byte; ảnh lại kết luận dung lượng thật và khớp 100% |

Các ca bổ sung mô tả hành vi an toàn cần đạt, được chạy trên bản sao package trong thư mục tạm. Chúng chỉ tạo file fixture nhỏ; không thử phá dữ liệu hoặc tháo ổ thật. Không cộng 14 ca này vào 84 test hiện có. ASAN qua không loại trừ lỗi logic, sai đơn vị SMART, rò Mach send-right hoặc rủi ro filesystem.

Workspace không có `.git`: chưa xác định được release commit, lịch sử thay đổi, branch protection hoặc secret trong lịch sử. [Danh sách SHA-256 nguồn](/Volumes/DATA/Code/MDriveHealth/audit/evidence/source-sha256.txt) xác định snapshot được kiểm tra. Chưa nghiệm thu macOS 14/15, runtime Intel, ổ SATA/HDD, cầu nối USB thật, FAT32/exFAT, pin, sleep dài, unplug giữa lúc ghi, hoặc app/DMG đã ký và notarize. Universal build chỉ chứng minh biên dịch cả hai kiến trúc.

## Những phần đang làm tốt

Core tách khỏi SwiftUI qua SwiftPM; không có package bên ngoài cần tải. State UI dùng MainActor, các truy vấn SQLite dùng bind tham số và queue tuần tự, có WAL, giảm ghi trùng và giới hạn lịch sử. Benchmark có buffer căn chỉnh, kiểm tra cấu hình cơ bản, quyền file mới 0600, cơ chế hủy và một số kiểm tra cache. Những nền tảng này nên giữ khi sửa lỗi.

Các helper gọi binary hệ thống bằng executable và mảng arguments, không ghép shell command từ input người dùng. Không thấy luồng yêu cầu root hoặc cài kext. Báo cáo văn bản đã che phần lớn serial. Kết nối mạng ứng dụng quan sát trong nguồn là kiểm tra GitHub release qua HTTPS; không thấy luồng gửi SMART hoặc serial tới backend. Quét pattern secret trong nguồn hiện tại không có hit, với giới hạn không có lịch sử Git.

Catalog có 400 key app và 59 key core, có bản tiếng Anh. Release script đã có các bước hardened runtime, ký, notarize, staple và Gatekeeper; cần nghiệm thu artifact cuối và bổ sung hồ sơ license.

App được cấu hình ngoài sandbox để truy cập SMART, nên an toàn đường dẫn và quyền filesystem là ranh giới bảo vệ quan trọng. Interface NVMe được port từ smartmontools và cảm biến dùng HID/IOKit: khả năng đọc trên host hiện tại chưa bảo đảm tương thích với mọi bản macOS hoặc bridge. Cần công bố capability theo thiết bị, giữ trạng thái unavailable rõ ràng và đưa những API này vào matrix tương thích F20/F22. Thiết kế phân phối hiện tại là ngoài App Store; chưa đánh giá một phương án chuyển kênh phát hành.

## Các vấn đề P1 chặn phát hành

### F01 Xóa file hoặc thư mục trước khi chứng minh quyền sở hữu

**Đã tái hiện.** [CapacityVerifier.swift:129](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/Benchmark/CapacityVerifier.swift:129) xóa đệ quy thư mục tên cố định trước khi chạy; [DiskBenchmarkEngine.swift:50](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/Benchmark/DiskBenchmarkEngine.swift:50) unlink file tên cố định trước `O_EXCL`. Hai fixture có file sentinel tồn tại trước đều mất, kể cả khi yêu cầu hủy ngay. `O_EXCL` không bảo vệ file đã bị unlink.

NSLock chỉ bảo vệ trong một process. Từ mã nguồn, CLI, app hoặc hai instance có thể dọn file của phiên khác; chưa chạy thử tranh chấp nhiều process trên volume thật. Cleanup cuối phiên cũng chỉ dựa vào đường dẫn, chưa xác minh inode hoặc chủ sở hữu.

**Sửa và nghiệm thu:** tạo tên duy nhất cho mỗi phiên bằng cơ chế tạo file/thư mục độc quyền; mở qua directory handle, chống chuyển hướng symlink; giữ thông tin ownership và chỉ dọn object của phiên. Dùng khóa hệ điều hành theo volume cho app và CLI. Test sentinel, symlink, đổi inode, hai process, hủy sớm và leftover không rõ nguồn phải chứng minh file ngoài phiên còn nguyên.

### F02 Có thể ghi vào filesystem khác khi mount point không còn hợp lệ

**Đã tái hiện bằng mount path giả lập.** [CapacityVerifier.swift:131](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/Benchmark/CapacityVerifier.swift:131) tạo cả thư mục cha. Với mount path không tồn tại, engine tự tạo đường dẫn đó rồi ghi lên filesystem chứa thư mục cha. Nếu `/Volumes/tên-ổ` biến mất và quyền cho phép tạo lại, thao tác có thể chuyển sang ổ hệ thống. Đường dẫn được tái sử dụng cho ổ khác cũng chưa được xác minh.

[BenchmarkLocation.swift:49](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/Benchmark/BenchmarkLocation.swift:49) kiểm tra filesystem đang ở đường dẫn ghi, nhưng không so với danh tính volume người dùng đã chọn; khi đọc live free space thất bại còn dùng snapshot cũ.

**Sửa và nghiệm thu:** lưu và xác minh volume UUID, fsid và liên hệ BSD device trước khi mở file; không tạo lại mount point; lỗi xác minh phải dừng. Giữ handle tới volume đã xác minh, kiểm tra lại khi tạo file tiếp theo. Test mất mount, đường dẫn tái sử dụng, symlink, quyền bị từ chối và thay ổ giữa phiên; không được tự ghi lên volume khác.

### F03 Lời hứa không ảnh hưởng dữ liệu trái với bản chất kiểm tra ổ giả

**Xác nhận từ UI và đặc tính kỹ thuật.** [BenchmarkTab.swift:486](/Volumes/DATA/Code/MDriveHealth/App/Views/BenchmarkTab.swift:486) khẳng định dữ liệu sẵn có không bị ảnh hưởng, trong khi nút tại dòng 470 bắt đầu ghi gần hết dung lượng trống và không có bước xác nhận đã sao lưu. Volume khởi động cũng có thể được chọn.

Trên flash có firmware khai khống, ghi vào địa chỉ logic còn trống có thể quay vòng và ghi đè dữ liệu cũ. Hướng dẫn chính thức của [F3](https://fight-flash-fraud.readthedocs.io/en/latest/usage.html) nêu rủi ro này khi thử thiết bị đang chứa dữ liệu. Do đó việc chỉ tạo file trong free space không bảo đảm an toàn cho loại ổ mà tính năng này muốn phát hiện.

**Sửa và nghiệm thu:** bỏ cam kết an toàn tuyệt đối; đưa bước xem lại volume, lượng ghi, dung lượng giữ lại và xác nhận dữ liệu đã sao lưu. Ưu tiên volume ngoài trống có thể xóa bỏ; chặn hoặc có quy trình riêng cho boot volume và APFS dùng chung dung lượng. CLI cũng cần điều kiện bắt đầu tương đương. Điều kiện này bảo vệ thao tác ghi, không liên quan đến quyết định thu phí.

### F04 Kết luận dung lượng vượt quá phạm vi dữ liệu đã kiểm tra

**Đã tái hiện một nhánh; các nhánh I/O còn lại xác nhận từ nguồn.** Ghi và đọc đúng 8 KiB trên fixture khai báo 1 TiB vẫn trả `.genuine` tại [CapacityVerifier.swift:180](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/Benchmark/CapacityVerifier.swift:180). API định nghĩa genuine theo byte đã ghi, nhưng UI tại [BenchmarkTab.swift:531](/Volumes/DATA/Code/MDriveHealth/App/Views/BenchmarkTab.swift:531) biến nó thành chứng nhận dung lượng thật của ổ.

Engine chỉ verify số byte đã ghi, không giữ trạng thái hoàn thành target. ENOSPC hoặc short write tại dòng 275 có thể làm fill kết thúc sớm, thậm chí 0 byte, rồi đi tới genuine nếu không có read error. Nhánh 0 byte này chưa được fault injection. Return value của `F_NOCACHE` và `F_FULLFSYNC` trong capacity cũng bị bỏ qua.

`firstCorruptionOffset` là vị trí logic của file đầu tiên đọc sai, không phải dung lượng NAND thật. Ghi vòng có thể làm hỏng ngay block đầu; lỗi cáp hoặc media cũng có thể làm dữ liệu sai. UI tại dòng 542 và CLI lại dùng offset để khẳng định chỉ từng đó dung lượng dùng được và ổ gian lận. [Cơ chế và ví dụ F3](https://fight-flash-fraud.readthedocs.io/en/latest/usage.html) cho thấy không thể suy ra dung lượng vật lý từ phép đồng nhất này.

**Sửa và nghiệm thu:** kết quả cần lượng yêu cầu, đã ghi, đã verify, độ phủ, lý do dừng và lỗi flush/cache. Dùng kết luận “phần đã kiểm tra khớp”, “phát hiện dữ liệu hỏng”, “chưa đủ bằng chứng”; chỉ xác nhận phạm vi thực sự hoàn tất. Không quy mọi corruption thành gian lận hoặc suy ra dung lượng thật từ first offset. Test giới hạn nhỏ, zero write, ENOSPC, short I/O, EINTR, flush thất bại và controller ghi vòng giả lập.

### F05 Gán ý nghĩa lỗi ATA chỉ dựa trên attribute ID

**Đã tái hiện.** [HealthEvaluator.swift:219](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/Scoring/HealthEvaluator.swift:219) xử lý ID cố định dù drivedb đã cung cấp tên theo model. Ví dụ ID 184 là `Factory_Bad_Block_Count` trên một số OCZ, ID 198 là `Host_Reads_GiB` trên một số SSD Indilinx/OCZ. Fixture raw 100 của từng counter bị đánh giá `.failing`. [DriveReading.swift:70](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/SMART/DriveReading.swift:70) còn cộng host reads thành media defects, tác động đến history, cảnh báo và RiskAdvisor.

**Sửa và nghiệm thu:** chuyển từ ID sang metric có ý nghĩa theo family/model/firmware, có đơn vị và độ tin cậy. Cùng một mapping phải phục vụ score, defect total, history và notification. Attribute vendor chưa hiểu không được tự diễn giải thành sector lỗi. Fixture theo các mục drivedb có ID trùng nghĩa khác phải không tạo cảnh báo sai, trong khi fixture lỗi thực vẫn cảnh báo đúng.

### F06 Diễn giải nhiệt độ hoặc số byte ghi thành phần trăm tuổi thọ

**Đã tái hiện.** [HealthEvaluator.swift:342](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/Scoring/HealthEvaluator.swift:342) lấy normalized current của ID đầu tiên trong `[231, 233, 169, 202, 177, 173]`. Trong drivedb, ID 231 có thể là `Controller_Temperature`, ID 233 là `NAND_GiB_Written`; cả hai fixture đều bị gán tuổi thọ còn 100%. Các ID khác cũng có nghĩa theo hãng và không có cùng chiều tăng/giảm.

**Sửa và nghiệm thu:** mapping endurance phải xác định nguồn raw/normalized, đơn vị, chiều biến đổi và miền hợp lệ theo thiết bị. Không có metric hợp lệ thì lifetime là unknown, không phải 100%. WearTrend chỉ tính trên các điểm cùng metric hợp lệ. Test nhiệt độ, lượng ghi NAND, phần trăm đã dùng/còn lại, counter reset và đổi firmware.

### F07 Decoder ATA bỏ qua byte order và thiếu byte của các format

**Đã tái hiện.** [ATAParser.swift:30](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/SMART/ATAParser.swift:30) chỉ truyền sáu raw byte và format, bỏ qua `ATAAttributeSpec.byteorder`. Fixture byte order `012345` giải mã ngược. [ATARawDecoder.swift:44](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/DriveDB/ATARawDecoder.swift:44) xử lý raw56/raw64/hex56/hex64 như raw48; raw64 fixture cần 78866 nhưng trả 1.

[Mã nguồn smartmontools](https://github.com/smartmontools/smartmontools/blob/master/smartmontools/atacmds.cpp) sử dụng cả reserved/current/worst tùy format, ví dụ raw64 có byte order `543210wv`. Các format raw24/raw32 và msec24hour32 cũng cần bảy byte; implementation hiện chỉ có sáu. Firmware fixes được lưu trong DriveDB nhưng chưa được áp dụng, cần rà lại cùng quá trình đối chiếu decoder.

**Sửa và nghiệm thu:** truyền đầy đủ dữ liệu attribute và byte order; đối chiếu kết quả bằng fixture với smartmontools cho từng format đang có trong DB, gồm custom byte order và firmware quirks. Kiểm tra numeric value, đơn vị và display; không chỉ kiểm tra chuỗi tên attribute.

### F08 Không đủ dữ liệu vẫn hiển thị sức khỏe hoàn hảo

**Đã tái hiện ở evaluator.** ATA reading không có identify, attribute hoặc overall status vẫn trả Good 100/100 từ [HealthEvaluator.swift:171](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/Scoring/HealthEvaluator.swift:171). [CSMART.c:181](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/CSMART/CSMART.c:181) chưa validate checksum SMART; identify trả `outSize` nhưng không kiểm tra. Chưa tạo lỗi checksum trên thiết bị thật. NVMe cũng cần xử lý trường nhiệt độ không khả dụng thay vì biến 0 K thành nhiệt độ âm.

**Sửa và nghiệm thu:** bổ sung validity, capabilities và trạng thái unknown/partial, độc lập với health rating. Dữ liệu thiếu hoặc sai không được đồng nghĩa với khỏe. Validate payload, checksum, độ dài identify và sentinel của trường số liệu; bảo toàn phần đọc được mà không chứng nhận phần thiếu. Test trang trống, checksum sai, payload thiếu, status không hỗ trợ và log NVMe với trường không hợp lệ.

### F09 Ảnh chia sẻ biến kết quả chưa kết luận thành dung lượng thật

**Đã render bằng view thật.** [ShareCards.swift:120](/Volumes/DATA/Code/MDriveHealth/App/Views/ShareCards.swift:120) chỉ phân biệt `.fake` với mọi trạng thái còn lại. Input `.inconclusive`, `bytesVerifiedOK = 0` tạo card xanh “DUNG LƯỢNG THẬT” và “dữ liệu khớp 100%”. Đây là bằng chứng tổng hợp từ fixture, không phải kết quả của ổ thật: [ảnh render](/Volumes/DATA/Code/MDriveHealth/audit/evidence/inconclusive-capacity-card.png).

**Sửa và nghiệm thu:** dùng switch đầy đủ mọi verdict; các view, text export, CLI và share card dùng cùng trình bày kết luận có phạm vi. Kiểm tra cả ba verdict, partial coverage và zero verification; trạng thái chưa kết luận phải giữ nguyên khi chia sẻ.

## Các vấn đề P2 về độ ổn định và phát hành

### F10 Lệnh phần cứng chưa có điều phối đầy đủ và có thể chặn UI

**Xác nhận từ nguồn; cần hardware fault test.** [SelfTestTab.swift:149](/Volumes/DATA/Code/MDriveHealth/App/Views/SelfTestTab.swift:149) gọi startSelfTest đồng bộ từ action UI. Các nút không bị vô hiệu hóa khi test đang chạy hoặc benchmark đang giữ ổ; đọc self-test log tại dòng 134 đi vòng ngoài guard của DriveStore. Vì vậy lời hứa tạm ngừng SMART trong benchmark chưa áp dụng cho mọi đường gọi.

[DriveStore.swift:88](/Volumes/DATA/Code/MDriveHealth/App/Models/DriveStore.swift:88) đọc nhiều ổ đồng thời nhưng chỉ publish sau khi toàn task group kết thúc. Một probe treo vẫn giữ toàn bộ refresh và dữ liệu mới của các ổ khác. Hủy Swift Task không tự ngắt lời gọi IOKit đồng bộ.

**Nghiệm thu:** có coordinator theo drive cho probe, benchmark, capacity, self-test và eject; UI không thực hiện I/O đồng bộ. Publish kết quả từng ổ, giới hạn concurrency, có timeout và trạng thái stalled. Với lời gọi không thể ngắt, cân nhắc worker/helper riêng thay vì hứa timeout chỉ bằng Task cancellation. Test một provider treo, thao tác chồng nhau và nhiều drive phải chứng minh UI và các drive khác vẫn cập nhật.

### F11 Có thể bỏ lỡ thông báo self-test hoàn tất

**Xác nhận từ state flow.** [MonitoringController.swift:182](/Volumes/DATA/Code/MDriveHealth/App/Models/MonitoringController.swift:182) chỉ ghi nhận đang chạy khi evaluateAlerts nhìn thấy trạng thái đó. Start self-test chỉ ghi `startedAt` trong view; refresh từ tab và nút thủ công không đánh giá alert. Test ngắn hoàn tất giữa hai poll, giữ terminal status 0 như lần trước, có thể không có `sawRun` hoặc `resultChanged`; lời hứa thông báo cả test hoàn tất giữa poll chưa được đáp ứng.

**Nghiệm thu:** lưu run intent sau khi lệnh bắt đầu thành công; phát hiện kết quả bằng identity của run/log mới, độc lập với cadence của notification timer. Test hoàn tất giữa poll, app restart, pass liên tiếp, failed liên tiếp và abort phải cho đúng một sự kiện.

### F12 Preference monitoring, baseline nhiệt độ và dữ liệu cũ chưa được xử lý nhất quán

**Xác nhận từ nguồn.** [MDriveHealthApp.swift:83](/Volumes/DATA/Code/MDriveHealth/App/MDriveHealthApp.swift:83) luôn gọi evaluateAlerts khi mở cửa sổ; hàm này không kiểm tra monitoringEnabled. [MonitoringController.swift:72](/Volumes/DATA/Code/MDriveHealth/App/Models/MonitoringController.swift:72) luôn xin quyền thông báo khi start. Nhánh over-temperature tại dòng 141 chỉ chạy khi có previous state: ổ đã nóng ngay lần đầu có thể không được cảnh báo nhiệt, rồi được ghi baseline là đang nóng. Snapshot stale hoặc giữ lại lúc sleeping vẫn đi qua cùng alert evaluation.

**Nghiệm thu:** mọi entrypoint tôn trọng preference; chỉ dùng reading mới, hợp lệ cho sự kiện mới. Xác định rõ chính sách cảnh báo lần đầu và dedup. UI phải phản ánh quyền thông báo denied và lỗi gửi thay vì im lặng. Test monitoring off khi launch/reopen, lần đầu quá nhiệt, stale reading, đổi ngưỡng và bật lại monitoring.

### F13 Hai ổ không có serial có thể dùng chung lịch sử

**Đã tái hiện.** [HistoryStore.swift:108](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/History/HistoryStore.swift:108) fallback về `model#sizeBytes` khi thiếu serial và mediaUUID. Hai ổ cùng model/dung lượng khác registry ID tạo cùng key. History, defect trend, backup reminders và trạng thái self-test có thể bị trộn.

**Nghiệm thu:** ưu tiên serial đã đọc từ SMART khi metadata discovery thiếu, sau đó identity media ổn định. Khi không định danh chắc chắn, tách session và hiển thị hạn chế thay vì gộp chắc chắn. Test hai ổ cùng model, đổi BSD name, reboot, unplug/replug. Notification/deep link hiện dựa registry ID tạm thời cũng cần cơ chế tra lại ổ sau restart.

### F14 Lỗi lưu lịch sử và xuất báo cáo dễ bị che mất

**Xác nhận từ nguồn.** [DriveStore.swift:45](/Volumes/DATA/Code/MDriveHealth/App/Models/DriveStore.swift:45) mở DB bằng `try?`; đọc và ghi tại dòng 135–140 tiếp tục bỏ lỗi. Benchmark history và nhiều query UI tương tự. [DriveDetailView.swift:170](/Volumes/DATA/Code/MDriveHealth/App/Views/DriveDetailView.swift:170) bỏ lỗi ghi báo cáo. Người dùng có thể thấy lịch sử rỗng hoặc tưởng export thành công.

[HistoryStore.swift:189](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/History/HistoryStore.swift:189) chỉ lặp khi SQLITE_ROW, không phân biệt kết thúc SQLITE_DONE với lỗi query; latest trả nil cho mọi kết quả không phải ROW. Migration `ALTER TABLE` tại dòng 100 bỏ mọi lỗi, chưa có schema version và transaction migration rõ ràng.

**Nghiệm thu:** store có trạng thái degraded, lỗi ghi/xuất hiển thị cùng khả năng thử lại; kiểm tra mã kết thúc SQLite. Migration có version, transaction và phục hồi. Test DB corrupt, read-only, full disk, busy và schema cũ; không được biến lỗi thành “chưa có dữ liệu”.

### F15 Quit hoặc đổi ngôn ngữ có thể bỏ lại file test lớn

**Rủi ro từ lifecycle; chưa kill phiên ghi lớn.** Chưa có bước applicationShouldTerminate phối hợp cancel và chờ cleanup của phiên ghi. [SettingsView.swift:147](/Volumes/DATA/Code/MDriveHealth/App/Views/SettingsView.swift:147) mở instance mới rồi terminate sau 0,4 giây mà không kiểm tra thao tác đang chạy. `defer` không chạy khi process bị kill hoặc mất điện. Leftover hiện chỉ được dọn lần chạy test sau và cơ chế đó gặp F01.

**Nghiệm thu:** quit/relaunch bình thường chờ hủy và cleanup; startup phát hiện leftover có manifest ownership từ phiên trước, hiển thị hoặc dọn an toàn. Test quit, relaunch, crash/kill ở từng phase trên volume fixture; không mất file bên ngoài phiên, không để hàng trăm GB không được báo.

### F16 Timeout quét log chưa bảo đảm và đầu ra không có giới hạn

**Xác nhận từ nguồn; chưa ép child process thật bỏ qua SIGTERM.** [IOErrorWatcher.swift:79](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/SystemHealth/IOErrorWatcher.swift:79) chỉ terminate, rồi block trong readDataToEndOfFile và waitUntilExit. Khác với DriveServices, không có escalation SIGKILL. Output lớn được giữ toàn bộ trong RAM. Timestamp parse thất bại tại dòng 99 bị thay bằng thời gian hiện tại, có thể đưa log cũ vào cửa sổ 24 giờ. Trạng thái scan không đọc được chưa có biểu đạt riêng rõ ràng trên UI.

**Nghiệm thu:** watchdog hai bước, drain streaming với giới hạn byte/event, cancellation và trạng thái unavailable. Timestamp sai phải unknown hoặc bị loại có diagnostics, không tự coi là hôm nay. Test child không chịu terminate, output rất lớn, log malformed và scan fail/retry.

### F17 Chuyển dung lượng trống âm sang UInt64 có thể crash

**Rủi ro tĩnh, chưa quan sát giá trị âm từ APFS trên host.** [BenchmarkLocation.swift:69](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/Benchmark/BenchmarkLocation.swift:69) dùng `UInt64.init` trên Int64. Giá trị âm sẽ trap; capacity engine đã có clamp cho cùng trường. Statfs thất bại cũng chưa dừng preflight.

**Nghiệm thu:** clamp hoặc từ chối dung lượng không hợp lệ; mount/free-space query thất bại phải dừng thao tác ghi. Dùng provider injectable để test số âm, lỗi statfs và snapshot stale mà không cần chờ APFS tạo edge case.

### F18 Cấu hình engine công khai chưa giới hạn đầy đủ

**Đã tái hiện validate chấp nhận infinity; không chạy benchmark vô hạn.** [BenchmarkModels.swift:57](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/Benchmark/BenchmarkModels.swift:57) không kiểm tra randomPhaseSeconds finite hoặc dương. Capacity config cũng chưa bảo vệ phép cộng reserve + block tại [CapacityVerifier.swift:152](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/Benchmark/CapacityVerifier.swift:152) khỏi overflow và chưa có ceiling hợp lý cho allocation. Nếu buffer thứ hai của verify allocation thất bại, buffer thứ nhất chưa được free trên nhánh guard.

**Nghiệm thu:** từ chối NaN/infinity/không dương, giới hạn duration và buffer, dùng arithmetic có kiểm tra overflow, giải phóng từng allocation trên mọi nhánh lỗi. Test extreme config ở validate, không thực hiện allocation khổng lồ hoặc ghi không giới hạn. UI hiện chưa trực tiếp nhập các giá trị cực đoan này, nên mức ưu tiên thấp hơn lỗi ghi dữ liệu P1.

### F19 Poll RAM rò tham chiếu Mach host port

**Đã tái hiện.** [MemoryReader.swift:41](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/SystemHealth/MemoryReader.swift:41) và dòng 47 gọi mach_host_self nhưng không mach_port_deallocate. Sau 100 lần đọc, send-right user references tăng từ 2 lên 202. Poll định kỳ làm tài nguyên tăng theo thời gian; chưa đo thời điểm hệ thống chịu ảnh hưởng trong phiên chạy dài.

**Nghiệm thu:** lấy một host handle, tái sử dụng và deallocate bằng defer kể cả khi đọc lỗi. Test số tham chiếu trước/sau nhiều lần poll ổn định, đồng thời theo dõi RSS/CPU/port trong phiên soak.

### F20 Artifact phát hành bị sửa linked SDK sau build

**Khoảng trống nghiệm thu, chưa chứng minh một lỗi runtime mới.** [release.sh:40](/Volumes/DATA/Code/MDriveHealth/scripts/release.sh:40) dùng vtool đổi linked SDK sang 15.0 sau archive nhằm xử lý ScrollView trắng trên macOS 15.7 theo ghi chú trong repo. Metadata này có thể ảnh hưởng hành vi tương thích của framework. Build và smoke test unsigned đã chạy không kiểm chứng binary sau bước sửa này.

**Nghiệm thu:** chạy chính app nằm trong DMG cuối cùng trên minimum OS, bản OS gặp lỗi và bản mới, với Apple Silicon và Intel nếu công bố hỗ trợ. Ưu tiên sửa nguyên nhân UI hoặc dùng toolchain được kiểm soát; nếu giữ workaround phải có fixture/smoke regression và phạm vi OS cụ thể. Pin toolchain, lưu hash, kết quả ký, notarization và Gatekeeper cho từng release. Pipeline hiện có các lệnh ký/notary nhưng audit chưa chạy phát hành bằng credentials.

### F21 Binary distribution thiếu bộ hồ sơ license và mã nguồn tương ứng

**Đã kiểm tra bundle build.** App hiện không có LICENSE/COPYING/NOTICE. [project.yml:18](/Volumes/DATA/Code/MDriveHealth/project.yml:18) chỉ đưa App vào nguồn; [release.sh:61](/Volumes/DATA/Code/MDriveHealth/scripts/release.sh:61) stage app và shortcut Applications. Dự án GPL-3.0-or-later, có drivedb và interface được port từ smartmontools GPL-2.0-or-later.

GPL cho phép thu tiền phân phối. Việc thu tiền không bỏ các quyền nhận, sửa và phân phối mã của người nhận; không thể chỉ đổi license của code hiện tại sang proprietary trong khi vẫn dùng những thành phần GPL đó. Cần chọn cách cung cấp corresponding source phù hợp cho bản binary thực sự phân phối, gồm phần sửa và script cần thiết để build. Xem [GNU về bán phần mềm tự do](https://www.gnu.org/philosophy/selling.en.html) và [GPLv3 mục 6](https://www.gnu.org/licenses/gpl-3.0.html). Kết luận này dựa trên license hiện tại, không quyết định thay người dùng mô hình kinh doanh hoặc điều khoản thương mại.

**Nghiệm thu:** bundle license, attribution và notice; About có license/source link tới đúng version. Mỗi release có source tương ứng và hướng dẫn build, kiểm tra nội dung DMG. Nghĩa vụ phân phối áp dụng cả khi miễn phí; đây không phải yêu cầu phải thu phí hoặc phải thêm backend.

### F22 CI chưa bao phủ luồng rủi ro của app và phần cứng

**Xác nhận cấu hình.** [ci.yml:10](/Volumes/DATA/Code/MDriveHealth/.github/workflows/ci.yml:10) chạy core Debug tests và app unsigned Release trên một runner macos-14; chưa có app unit/UI target, matrix runtime phần cứng hoặc nghiệm thu artifact sau đóng gói. Label runner không tự chứng minh app hoạt động trên toàn bộ OS hỗ trợ. 84 test hiện tại qua cùng lúc những guard an toàn mới thất bại.

**Nghiệm thu:** đưa các hợp đồng đã sửa vào suite chính, không chỉ thêm assertion mô phỏng implementation. Tách provider filesystem/SMART/clock/notification để test lỗi, stale state và thời gian. Có app tests cho preferences, alerts, verdict presentation và selection; stress cancellation/concurrency; C sanitizer/analysis; nghiệm thu macOS tối thiểu và mới. Ghi rõ hardware test nào thật sự chạy, skip phải thể hiện trong kết quả. CI cần xác nhận chạy trên repo thật; branch protection chưa thể xác minh từ workspace không có Git.

## Các vấn đề P3 về cập nhật và chất lượng sản phẩm

### F23 Kiểm tra phiên bản cần xử lý metadata chính xác hơn

[UpdateChecker.swift:66](/Volumes/DATA/Code/MDriveHealth/App/Models/UpdateChecker.swift:66) split và compactMap Int không xử lý version prerelease đúng; ví dụ `1.2.1-beta` bị thành `[1, 2]`. Không có timeout riêng cho UX hoặc nút hủy, fallback asset đầu tiên có thể không phải bộ cài. Đây là rủi ro logic từ nguồn, chưa tạo test mạng giả lập.

Nên parse phiên bản theo format release đã cam kết, chọn đúng DMG theo tên/platform, có timeout, retry và lỗi rõ ràng. Luồng cập nhật hiện chỉ mở trang/download; chưa tự chạy binary tải về. Manual update vẫn là lựa chọn hợp lệ cho production. Nếu bổ sung auto-update sau này cần signature verification và kiểm tra downgrade theo thiết kế updater.

### F24 Metadata và UI cần thống nhất với hành vi thực

[project.yml:28](/Volumes/DATA/Code/MDriveHealth/project.yml:28) khai báo plist 0.1.1/build 2, nhưng build settings tại dòng 43 là 0.1.0/build 1. [Cask draft](/Volumes/DATA/Code/MDriveHealth/packaging/homebrew-cask/mdrivehealth.rb:6) còn 0.1.0 và sha256 no_check. README còn số lượng test cũ và cần nói rõ hỗ trợ USB SMART phụ thuộc bridge/driver. Dùng một nguồn version và checksum DMG thật khi phát hành; cập nhật tài liệu sau khi chốt hỗ trợ.

Smoke test tiếng Anh còn thấy nhóm sensor “Khác”; [SensorsReader.swift:56](/Volumes/DATA/Code/MDriveHealth/Packages/MDriveHealthCore/Sources/MDriveHealthCore/SystemHealth/SensorsReader.swift:56) tạo tên động nên việc đủ key trong catalog chưa chứng minh mọi chuỗi được dịch. [BenchmarkTab.swift:197](/Volumes/DATA/Code/MDriveHealth/App/Views/BenchmarkTab.swift:197) khẳng định FileVault với boot volume mà chưa đọc trạng thái. Onboarding dùng giọng “mày”, nên thống nhất giọng phù hợp người mua trước khi thương mại hóa.

Selection ban đầu có thể chọn RAM khi chưa enumerate xong, ổ bị tháo chưa luôn có fallback selection và notification dùng ID tạm thời. Cần UI smoke cho launch, đổi số lượng/identity ổ, disconnect/reconnect, ngôn ngữ, window nhỏ, keyboard và accessibility/VoiceOver. Các tình huống accessibility chưa được nghiệm thu trong audit này.

## Thứ tự sửa và điều kiện nghiệm thu

1. **An toàn ghi dữ liệu:** F01–F04, F09. Nếu cần phát bản beta sớm, tạm ẩn/khóa capacity và các đường ghi chưa an toàn, nói rõ phạm vi beta. Cơ chế ghi chỉ trở lại sau khi ownership, mount identity, cancellation và verdict có test đạt.
2. **Tính đúng của chẩn đoán:** F05–F08. Tạo lớp canonical metrics, decoder tương đương nguồn tham chiếu và trạng thái unknown. Chưa thêm phân tích tuổi thọ hoặc lời hứa dự báo mới trước khi nền dữ liệu này đúng.
3. **Monitoring và vận hành dài:** F10–F19. Điều phối drive operations, ghi run identity, sửa persistence và báo lỗi, sửa leak/watchdog; nghiệm thu sleep/wake, restart và fixture lỗi.
4. **Artifact phát hành:** F20–F24. Version thống nhất, license/source tương ứng, CI chạy thật, kiểm tra app từ DMG đã ký/notarize trên matrix OS/hardware công bố.

| Điều kiện | Bằng chứng cần có trước production |
| --- | --- |
| Không làm mất dữ liệu ngoài phiên | Các guard F01/F02 và test multi-process/symlink/unplug đều đạt trên fixture; kiểm tra volume thử nghiệm có thể xóa bỏ |
| Kết luận đúng phạm vi | Không có đường zero/partial/inconclusive thành chứng nhận toàn ổ; mọi UI/export/CLI thống nhất |
| SMART đáng tin cậy | Fixture nhiều family/vendor, byteorder/raw formats/invalid payload qua; đối chiếu SMART thực trên phần cứng được hỗ trợ |
| Monitoring đúng sự kiện | Clock và notification giả lập chứng minh first sighting, off, stale, restart, completion và dedup; không trộn hai ổ |
| Chịu lỗi và chạy lâu | DB lỗi, process treo, cancel/quit/crash recovery qua; soak tối thiểu 24 giờ gồm sleep/wake không tăng tài nguyên vô hạn |
| Phát hành có thể tái dựng | Exact source snapshot/tag, toolchain, source artifact, license, hash app/DMG, codesign/notary/Gatekeeper và smoke trên bản đóng gói |

Mốc soak 24 giờ là tiêu chí đề xuất để bắt lỗi tài nguyên và lifecycle trước mắt, không phải chứng minh không bao giờ crash. OS/hardware chưa có trong matrix phải được ghi là chưa hỗ trợ hoặc chưa xác minh. Score sức khỏe là heuristic theo dữ liệu đọc được, không nên quảng bá như xác suất hỏng hoặc bảo đảm dữ liệu an toàn.

## Tính năng nâng cấp đáng cân nhắc sau khi ổn định

Giá trị có thể khiến người dùng trả tiền nằm ở **chẩn đoán có căn cứ và monitoring đáng tin**, vì người dùng có thể ra quyết định sao lưu/thay ổ từ kết quả. Các hướng phù hợp gồm lịch sử và trend có giải thích độ tin cậy; notification có thể kiểm chứng; kiểm tra dung lượng an toàn với báo cáo phạm vi; báo cáo chẩn đoán che thông tin riêng tư; quản lý nhiều ổ và export dữ liệu dễ dùng.

Có thể bổ sung checklist kiểm tra backup, quy trình hỗ trợ với diagnostics cục bộ do người dùng chủ động xuất, cập nhật đã ký và phạm vi thiết bị hỗ trợ rõ ràng. Không cần telemetry từ xa để sửa những lỗi hiện tại. Nếu sau này thu thập dữ liệu, cần mô tả chính xác dữ liệu/retention và cơ chế đồng ý theo thiết kế thực tế.

Chưa nên đầu tư paywall trước các mốc an toàn và độ chính xác. Sau khi nghiệm thu, chọn kênh phân phối, hỗ trợ/cập nhật, chính sách hoàn tiền và tính năng có giá trị; khi đó mới thiết kế license/payment phù hợp với GPL và cách vận hành đã chọn.

## Chạy lại các bằng chứng

[run_repros.py](/Volumes/DATA/Code/MDriveHealth/audit/run_repros.py) sao chép core vào thư mục tạm và thêm [14 ca kiểm tra](/Volumes/DATA/Code/MDriveHealth/audit/repros/ProductionAuditRepros.swift). Mặc định xóa bản sao sau khi chạy. Muốn giữ log và package, truyền một output directory rỗng:

```bash
python3 audit/run_repros.py --output-dir /tmp/mdrivehealth-audit-rerun
```

Trên snapshot audit, exit code 1 và 15 assertion thất bại là kết quả dự kiến. Sau khi sửa đúng hợp đồng, các guard tương ứng phải qua; vẫn cần bổ sung những fault/hardware test ghi trong từng phát hiện. Test benchmark sentinel dùng internal seam để tránh ghi volume thật; production đi qua cùng đoạn unlink/open.

[render_capacity_fixture.py](/Volumes/DATA/Code/MDriveHealth/audit/render_capacity_fixture.py) build bản sao core với hai view app thật và input tổng hợp. Không đọc phần cứng. Output chưa được tồn tại:

```bash
python3 audit/render_capacity_fixture.py --output /tmp/mdrivehealth-inconclusive-card.png
```

Các log bằng chứng không chứa serial của thiết bị thật. Snapshot hash loại trừ build output, project sinh từ XcodeGen và `audit/`. Build warnings đáng dọn gồm unused MainActor.run result và capture self khác ownership; warning AppIntents metadata không phải lỗi vì project không dùng AppIntents. [Tóm tắt xác minh](/Volumes/DATA/Code/MDriveHealth/audit/evidence/verification-summary.json) ghi kết quả đã thực thi và giới hạn.
