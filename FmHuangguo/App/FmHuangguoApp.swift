import SwiftUI
import UIKit

// MARK: - 播放页之外的屏幕方向锁（竖屏）

final class AppDelegate: NSObject, UIApplicationDelegate {
    static var orientationLock: UIInterfaceOrientationMask = .portrait

    func application(_ application: UIApplication,
                     supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        AppDelegate.orientationLock
    }
}

// MARK: - App 入口

@main
struct FmHuangguoApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var app = AppState()
    @StateObject private var lib = LibraryStore.shared
    @StateObject private var speedPrefs = SpeedPrefs.shared
    @StateObject private var cacheManager = VideoCacheManager.shared
    @StateObject private var theme = ThemePrefs.shared

    init() {
        // 崩溃捕获：NSException/Signal 写入 debug.log（定位 mpv 闪退）
        DebugLogger.installCrashHandler()

        // 底部 TabBar / 导航栏不透明背景（修复 iOS 15 半透明导致的"全透明"观感）
        let tabAppearance = UITabBarAppearance()
        tabAppearance.configureWithOpaqueBackground()
        tabAppearance.backgroundColor = UIColor.systemBackground
        UITabBar.appearance().standardAppearance = tabAppearance
        if #available(iOS 15.0, *) {
            UITabBar.appearance().scrollEdgeAppearance = tabAppearance
        }
        let navAppearance = UINavigationBarAppearance()
        navAppearance.configureWithOpaqueBackground()
        navAppearance.backgroundColor = UIColor.systemBackground
        UINavigationBar.appearance().standardAppearance = navAppearance
        UINavigationBar.appearance().compactAppearance = navAppearance
        if #available(iOS 15.0, *) {
            UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
        }
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(app)
                .environmentObject(lib)
                .environmentObject(speedPrefs)
                .environmentObject(cacheManager)
                .environmentObject(theme)
                .preferredColorScheme(theme.mode.colorScheme)
        }
    }
}

// MARK: - 配色偏好

enum ThemeMode: String, CaseIterable, Identifiable {
    case system = "跟随系统"
    case light = "浅色"
    case dark = "深色"

    var id: String { rawValue }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

final class ThemePrefs: ObservableObject {
    static let shared = ThemePrefs()

    @Published var mode: ThemeMode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: "theme_mode") }
    }

    private init() {
        mode = ThemeMode(rawValue: UserDefaults.standard.string(forKey: "theme_mode") ?? "") ?? .system
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var lib: LibraryStore

    var body: some View {
        if app.phase == .ready {
            MainTabView()
                .task {
                    // 进入主界面后静默执行每日更新检测（历史+收藏，当天仅一次）
                    await UpdateChecker.checkIfNeeded(lib: lib)
                }
        } else {
            RouteSplashView()
        }
    }
}

// MARK: - 主界面 Tab

struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationView { HomeView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("首页", systemImage: "play.rectangle.fill") }

            NavigationView { HistoryView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }

            NavigationView { FavoritesView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("收藏", systemImage: "heart.fill") }

            NavigationView { DownloadsView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("缓存", systemImage: "arrow.down.circle.fill") }

            NavigationView { SettingsView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
    }
}
