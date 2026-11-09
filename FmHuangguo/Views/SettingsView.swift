import SwiftUI

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @State private var cacheCleared = false

    var body: some View {
        Form {
            Section(header: Text("线路（点击切换）")) {
                if app.routes.isEmpty {
                    HStack {
                        Text("当前线路")
                        Spacer()
                        Text(app.current?.host ?? SiteAPI.shared.base)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                } else {
                    ForEach(app.routes) { r in
                        Button {
                            app.select(r)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: r.tested ? (r.ok ? "checkmark.circle.fill" : "xmark.circle") : "circle")
                                    .foregroundColor(r.ok ? .green : (r.tested ? .red : .gray))
                                    .font(.system(size: 15))
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(r.name)
                                        .font(.system(size: 14))
                                        .foregroundColor(.primary)
                                    Text(r.host)
                                        .font(.system(size: 11))
                                        .foregroundColor(.secondary)
                                        .lineLimit(1)
                                }
                                Spacer()
                                if let ms = r.latencyMs {
                                    Text("\(ms)ms")
                                        .font(.system(size: 12, weight: .semibold))
                                        .foregroundColor(.green)
                                } else if r.tested {
                                    Text("不可用")
                                        .font(.system(size: 12))
                                        .foregroundColor(.secondary)
                                }
                                if app.current?.url == r.url {
                                    Text("使用中")
                                        .font(.system(size: 10, weight: .semibold))
                                        .padding(.horizontal, 6).padding(.vertical, 2)
                                        .background(Color.accentColor.opacity(0.15))
                                        .foregroundColor(.accentColor)
                                        .cornerRadius(6)
                                }
                            }
                        }
                    }
                }
                Button {
                    Task { await app.startRouting() }
                } label: {
                    Label("重新测速并自动选择最快线路", systemImage: "speedometer")
                        .font(.system(size: 14, weight: .medium))
                }
            }

            Section(header: Text("数据")) {
                Button {
                    URLCache.shared.removeAllCachedResponses()
                    CryptoImageLoader.shared.clearCache()
                    cacheCleared = true
                } label: {
                    Label("清除图片与数据缓存", systemImage: "trash")
                        .font(.system(size: 14))
                }
            }

            Section(header: Text("关于")) {
                row("应用名称", "Fm黄果")
                row("版本", "1.0.0")
                row("适用系统", "iOS 15.4+")
            }

            Section(footer: Text("本应用为个人学习研究用途的视频播放器外壳，所有视频内容均来自互联网公开网站，与本应用无关。请支持正版。本应用内容仅面向年满 18 周岁的成年用户。")) {
                EmptyView()
            }
        }
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.inline)
        .alert("缓存已清除", isPresented: $cacheCleared) {
            Button("确定", role: .cancel) {}
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 14))
            Spacer()
            Text(value)
                .font(.system(size: 13))
                .foregroundColor(.secondary)
        }
    }
}
