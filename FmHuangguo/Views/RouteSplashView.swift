import SwiftUI

// MARK: - 启动页：发现线路 → 并发测速 → 自动选最快进入

struct RouteSplashView: View {
    @EnvironmentObject private var app: AppState
    @State private var autoStarted = false
    @State private var logoScale: CGFloat = 0.9
    @State private var contentOpacity: Double = 0

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color(red: 0.32, green: 0.10, blue: 0.55),
                                    Color(red: 0.13, green: 0.33, blue: 0.85)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()

            VStack(spacing: 22) {
                Spacer()

                // App 图标块（呼吸动效）
                ZStack {
                    RoundedRectangle(cornerRadius: 24, style: .continuous)
                        .fill(LinearGradient(colors: [Color(red: 0.98, green: 0.27, blue: 0.57),
                                                      Color(red: 0.85, green: 0.15, blue: 0.45)],
                                             startPoint: .top, endPoint: .bottom))
                        .frame(width: 86, height: 86)
                        .shadow(color: Color(red: 0.98, green: 0.27, blue: 0.57).opacity(0.55), radius: 18, y: 6)
                    Text("FM")
                        .font(.system(size: 34, weight: .heavy))
                        .foregroundColor(.white)
                }
                .scaleEffect(logoScale)
                .onAppear {
                    withAnimation(.easeInOut(duration: 1.6).repeatForever(autoreverses: true)) {
                        logoScale = 1.04
                    }
                }

                Text("Fm黄果")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundColor(.white)
                Text("短剧极速播放器 · 自动选择最快线路")
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.75))

                Spacer()

                routeSection

                Spacer()
            }
            .padding(28)
            .opacity(contentOpacity)
        }
        .onAppear {
            withAnimation(.easeOut(duration: 0.45)) {
                contentOpacity = 1
            }
        }
        .task {
            // 仅冷启动时自动测速；从设置页"重新测速"进入时 phase 已是 routing
            guard app.phase == .boot else { return }
            await app.startRouting()
        }
    }

    @ViewBuilder
    private var routeSection: some View {
        VStack(spacing: 10) {
            if app.phase == .failed {
                VStack(spacing: 14) {
                    Image(systemName: "wifi.exclamationmark")
                        .font(.system(size: 36))
                        .foregroundColor(.white.opacity(0.9))
                    Text("所有线路均不可用，请检查网络后重试")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.9))
                        .multilineTextAlignment(.center)
                    Button {
                        Task { await app.startRouting() }
                    } label: {
                        Text("重新测速")
                            .font(.subheadline).fontWeight(.semibold)
                            .padding(.horizontal, 30).padding(.vertical, 10)
                            .background(Color.white)
                            .foregroundColor(Color(red: 0.25, green: 0.20, blue: 0.70))
                            .cornerRadius(20)
                    }
                }
            } else {
                ForEach(app.routes) { r in
                    routeRow(r)
                }
                if app.routes.isEmpty {
                    HStack(spacing: 10) {
                        ProgressView().tint(.white)
                        Text("正在获取线路列表…")
                            .font(.footnote)
                            .foregroundColor(.white.opacity(0.85))
                    }
                }
                Text(statusText)
                    .font(.footnote)
                    .foregroundColor(.white.opacity(0.8))
            }
        }
    }

    private var statusText: String {
        if let c = app.current, app.phase == .ready { return "已连接最快线路：\(c.host)" }
        return "正在测速，完成后自动进入最快线路…"
    }

    private func routeRow(_ r: RouteCandidate) -> some View {
        let isBest = app.routes.first(where: { $0.ok })?.url == r.url
        return HStack(spacing: 10) {
            Circle()
                .fill(r.tested ? (r.ok ? Color.green : Color.red.opacity(0.8)) : Color.white.opacity(0.35))
                .frame(width: 8, height: 8)
            Text(r.name)
                .font(.system(size: 14, weight: isBest ? .bold : .medium))
                .foregroundColor(.white)
                .frame(width: 110, alignment: .leading)
            Text(r.host)
                .font(.system(size: 12))
                .foregroundColor(.white.opacity(0.65))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if r.tested {
                if r.ok {
                    Text("\(r.latencyMs ?? 0)ms")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundColor(isBest ? Color(red: 1.0, green: 0.85, blue: 0.35) : Color(red: 0.55, green: 0.95, blue: 0.6))
                } else {
                    Text("不可用")
                        .font(.system(size: 12))
                        .foregroundColor(.white.opacity(0.45))
                }
            } else {
                ProgressView().tint(.white).scaleEffect(0.7)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.white.opacity(isBest ? 0.18 : 0.10))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isBest ? Color(red: 1.0, green: 0.85, blue: 0.35).opacity(0.8) : Color.white.opacity(0.08),
                        lineWidth: isBest ? 1.5 : 1)
        )
    }
}
