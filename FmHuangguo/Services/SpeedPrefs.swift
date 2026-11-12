import Foundation
import SwiftUI

// MARK: - 长按倍速偏好（设置页可调，UserDefaults 持久化）

final class SpeedPrefs: ObservableObject {
    static let shared = SpeedPrefs()

    /// 长按画面时临时应用的倍速（默认 2.0，可调 0.5~5.0）
    @Published var longPressSpeed: Double {
        didSet {
            UserDefaults.standard.set(longPressSpeed, forKey: "long_press_speed")
            longPressSpeed = max(0.5, min(5.0, longPressSpeed))
        }
    }

    private init() {
        let saved = UserDefaults.standard.double(forKey: "long_press_speed")
        longPressSpeed = saved > 0 ? saved : 2.0
    }

    func adjust(_ step: Double) {
        longPressSpeed += step
    }
}
