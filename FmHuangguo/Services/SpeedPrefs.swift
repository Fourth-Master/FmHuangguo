import Foundation
import SwiftUI

// MARK: - 长按倍速偏好（设置页可调，UserDefaults 持久化）

final class SpeedPrefs: ObservableObject {
    static let shared = SpeedPrefs()

    /// 长按画面时临时应用的倍速（默认 2.0，可调 0.5~5.0）
    @Published var longPressSpeed: Double

    private init() {
        let saved = UserDefaults.standard.double(forKey: "long_press_speed")
        longPressSpeed = saved > 0 ? saved : 2.0
    }

    /// 设置倍速（钳制 0.5~5.0 并持久化；不用 didSet 防递归）
    func set(_ value: Double) {
        let clamped = max(0.5, min(5.0, value))
        longPressSpeed = clamped
        UserDefaults.standard.set(clamped, forKey: "long_press_speed")
    }

    func adjust(_ step: Double) {
        set(longPressSpeed + step)
    }
}
