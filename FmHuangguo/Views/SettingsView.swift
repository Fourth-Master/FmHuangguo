import SwiftUI

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var gesturePrefs: GesturePrefs
    @EnvironmentObject private var cache: VideoCacheManager
    @EnvironmentObject private var theme: ThemePrefs
    @State private var cacheCleared = false
    @State private var logCleared = false
    @State private var showLogViewer = false
    @State private var shareSheetActive = false

    var body: some View {
        Form {
            Section(header: Text("外观")) {
                Picker("配色模式", selection: Binding(
                    get: { theme.mode },
                    set: { theme.mode = $0 }
                )) {
                    ForEach(ThemeMode.allCases) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .font(.system(size: 14))
            }

            Section(header: Text("播放器手势自定义")) {
                gesturePicker(title: "双击画面", slot: "gesture_double_tap",
                              binding: Binding(get: { gesturePrefs.doubleTap },
                                               set: { gesturePrefs.set($0, for: "gesture_double_tap") }))
                gesturePicker(title: "长按画面", slot: "gesture_long_press",
                              binding: Binding(get: { gesturePrefs.longPress },
                                               set: { gesturePrefs.set($0, for: "gesture_long_press") }))
                gesturePicker(title: "长按后上下滑动", slot: "gesture_lp_drag",
                              binding: Binding(get: { gesturePrefs.longPressVerticalDrag },
                                               set: { gesturePrefs.set($0, for: "gesture_lp_drag") }))
                Button {
                    gesturePrefs.reset()
                } label: {
                    Text("恢复默认手势")
                        .font(.system(size: 14))
                }
            }

            Section(header: Text("离线缓存")) {
                row("已缓存视频数", "\(cache.cachedEpisodes.values.filter { $0.done }.count) 集")
                row("占用空间", ByteCountFormatter.string(fromByteCount: cache.totalSize(), countStyle: .file))
            }
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
                    Task { await app.startRouting(force: true) }
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

            Section(header: Text("调试")) {
                Button {
                    showLogViewer = true
                } label: {
                    Label("查看调试日志", systemImage: "doc.text.magnifyingglass")
                        .font(.system(size: 14))
                }
                Button {
                    shareLog()
                } label: {
                    Label("导出日志（分享）", systemImage: "square.and.arrow.up")
                        .font(.system(size: 14))
                }
                Button(role: .destructive) {
                    DebugLogger.shared.clear()
                    logCleared = true
                } label: {
                    Label("清空调试日志", systemImage: "eraser")
                        .font(.system(size: 14))
                }
            }

            Section(header: Text("关于")) {
                row("应用名称", "Fm黄果")
                row("版本", Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0")
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
        .alert("日志已清空", isPresented: $logCleared) {
            Button("确定", role: .cancel) {}
        }
        .sheet(isPresented: $showLogViewer) {
            DebugLogViewer()
        }
        .sheet(isPresented: $shareSheetActive) {
            ActivitySheet(items: [DebugLogger.shared.fileForSharing])
        }
    }

    private func shareLog() {
        // 确保日志已落盘
        DebugLogger.shared.log("---- 导出日志 ----")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            shareSheetActive = true
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

    /// 手势动作选择器
    private func gesturePicker(title: String, slot: String, binding: Binding<PlayerGestureAction>) -> some View {
        Picker(title, selection: binding) {
            ForEach(PlayerGestureAction.allCases) { action in
                Text(action.label).tag(action)
            }
        }
        .font(.system(size: 14))
    }
}

// MARK: - 日志查看器

struct DebugLogViewer: View {
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var shareSheetActive = false

    var body: some View {
        NavigationView {
            ScrollView {
                Text(text.isEmpty ? "暂无日志" : text)
                    .font(.system(size: 11, design: .monospaced))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .textSelection(.enabled)
            }
            .navigationTitle("调试日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .navigationBarTrailing) {
                    Button {
                        shareSheetActive = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    Button {
                        DebugLogger.shared.clear()
                        text = ""
                    } label: {
                        Image(systemName: "trash")
                    }
                }
            }
            .onAppear {
                text = DebugLogger.shared.readAll()
            }
            .sheet(isPresented: $shareSheetActive) {
                ActivitySheet(items: [DebugLogger.shared.fileForSharing])
            }
        }
        .navigationViewStyle(.stack)
    }
}

// MARK: - 系统分享面板

struct ActivitySheet: UIViewControllerRepresentable {
    let items: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
