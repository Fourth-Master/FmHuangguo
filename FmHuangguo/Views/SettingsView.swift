import SwiftUI

// MARK: - 设置

struct SettingsView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var speedPrefs: SpeedPrefs
    @EnvironmentObject private var cache: VideoCacheManager
    @EnvironmentObject private var theme: ThemePrefs
    @State private var cacheCleared = false
    @State private var logCleared = false
    /// iOS 15 同一视图挂多个 .sheet 只有一个生效——统一走 item 驱动的单 sheet
    @State private var activeSheet: SettingsSheet?
    /// 长按倍速行内编辑框内容（直接在设置页改数字，不弹窗）
    @State private var speedText = ""
    @FocusState private var speedFieldFocused: Bool

    enum SettingsSheet: Identifiable {
        case logViewer, shareLog
        var id: Self { self }
    }

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

            Section(header: Text("长按倍速调整"), footer: Text("长按画面时临时应用该倍速，松开恢复原速。可直接改数字，或用 −/+ 微调。范围 0.5x~5.0x。")) {
                HStack(spacing: 16) {
                    Button {
                        speedPrefs.adjust(-0.1)
                        speedText = String(format: "%.1f", speedPrefs.longPressSpeed)
                    } label: {
                        Image(systemName: "minus.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                    // 行内直接编辑：iOS 15 上 alert 不支持嵌输入框、sheet 又与
                    // 同视图其他 sheet 冲突，直接在数字处改最稳
                    TextField("0.5~5.0", text: $speedText)
                        .keyboardType(.decimalPad)
                        .focused($speedFieldFocused)
                        .multilineTextAlignment(.center)
                        .font(.system(size: 22, weight: .bold, design: .monospaced))
                        .foregroundColor(.accentColor)
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .overlay(
                            RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .stroke(Color.accentColor.opacity(0.35), lineWidth: 1)
                        )
                        .frame(width: 96)
                        .toolbar {
                            // decimalPad 没有收起键：键盘工具条加"完成"收起（iOS 15 支持）
                            ToolbarItemGroup(placement: .keyboard) {
                                Spacer()
                                Button("完成") { speedFieldFocused = false }
                            }
                        }
                        .onAppear {
                            speedText = String(format: "%.1f", speedPrefs.longPressSpeed)
                        }
                        .onChange(of: speedText) { t in
                            // 输入合法值即时生效（非法/越界输入不提交）
                            if let v = Double(t), v >= 0.5, v <= 5.0 {
                                speedPrefs.set(v)
                            }
                        }
                    Spacer()
                    Button {
                        speedPrefs.adjust(0.1)
                        speedText = String(format: "%.1f", speedPrefs.longPressSpeed)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 26))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 4)
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
                    activeSheet = .logViewer
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
                row("应用名称", "FM短剧")
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
        .sheet(item: $activeSheet) { sheet in
            switch sheet {
            case .logViewer:
                DebugLogViewer()
            case .shareLog:
                ActivitySheet(items: [DebugLogger.shared.fileForSharing])
            }
        }
    }

    private func shareLog() {
        // 确保日志已落盘
        DebugLogger.shared.log("---- 导出日志 ----")
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            activeSheet = .shareLog
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
