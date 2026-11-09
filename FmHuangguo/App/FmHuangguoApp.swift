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

    init() {
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
                .preferredColorScheme(.light)
        }
    }
}

struct RootView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        if app.phase == .ready {
            MainTabView()
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

            NavigationView { SearchView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }

            NavigationView { HistoryView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("历史", systemImage: "clock.arrow.circlepath") }

            NavigationView { FavoritesView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("收藏", systemImage: "heart.fill") }

            NavigationView { SettingsView() }
                .navigationViewStyle(.stack)
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
        }
    }
}
