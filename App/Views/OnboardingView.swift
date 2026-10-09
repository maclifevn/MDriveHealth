/*
 * OnboardingView.swift — 4-step first-run tour: health score, background
 * monitoring, launch at login, and the USB-SMART expectation (the #1 source
 * of one-star confusion).
 * This file is part of MDriveHealth, licensed under GPL-3.0-or-later.
 */

import SwiftUI

struct OnboardingView: View {
    @Binding var isPresented: Bool
    @Environment(LoginItemController.self) private var loginItems
    @State private var step = 0

    private let stepCount = 4

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: stepIcon)
                .font(.system(size: 44))
                .foregroundStyle(.tint)
                .frame(height: 56)

            Text(stepTitle)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            stepBody
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(minHeight: 84, alignment: .top)

            if step == 2 {
                LoginItemControl(controller: loginItems)
            }

            HStack(spacing: 6) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Circle()
                        .fill(index == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }

            HStack {
                if step > 0 {
                    Button("Quay lại") { step -= 1 }
                }
                Spacer()
                Button(step == stepCount - 1 ? "Bắt đầu dùng" : "Tiếp tục") {
                    if step == stepCount - 1 {
                        isPresented = false
                    } else {
                        step += 1
                    }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
        .frame(width: 460)
    }

    private var stepIcon: String {
        ["gauge.with.needle", "bell.badge", "power", "cable.connector"][step]
    }

    private var stepTitle: LocalizedStringKey {
        switch step {
        case 0: return "onboarding.health.title"
        case 1: return "Theo dõi nền & cảnh báo"
        case 2: return "Tự chạy khi đăng nhập"
        default: return "Lưu ý về ổ USB"
        }
    }

    @ViewBuilder
    private var stepBody: some View {
        switch step {
        case 0:
            Text("onboarding.health.body")
        case 1:
            Text("onboarding.monitoring.body")
        case 2:
            Text("onboarding.login.body")
        default:
            Text("Khả năng đọc SMART của ổ USB phụ thuộc chip cầu nối và driver. Không đọc được SMART chưa đủ để kết luận ổ bị lỗi. Bạn vẫn có thể đo tốc độ hoặc kiểm tra dữ liệu trên phần dung lượng trống; ghi thử cần sao lưu trước.")
        }
    }
}
