import Foundation
import SwiftUI

// MARK: - 播放器手势动作定义

enum PlayerGestureAction: String, CaseIterable, Identifiable {
    case togglePlay      // 暂停/播放
    case fillToggle      // 填充/完整切换
    case speedUpLongPress // 长按倍速
    case speedDrag       // 长按上下滑调倍速
    case none            // 无操作

    var id: String { rawValue }

    var label: String {
        switch self {
        case .togglePlay: return "暂停/播放"
        case .fillToggle: return "画面填充切换"
        case .speedUpLongPress: return "临时 2x 倍速"
        case .speedDrag: return "上下滑调倍速"
        case .none: return "无操作"
        }
    }
}

// MARK: - 手势偏好（设置页可自定义，UserDefaults 持久化）

final class GesturePrefs: ObservableObject {
    static let shared = GesturePrefs()

    /// 手势 -> 动作映射
    @Published var doubleTap: PlayerGestureAction
    @Published var longPress: PlayerGestureAction
    @Published var longPressVerticalDrag: PlayerGestureAction

    private init() {
        let d = UserDefaults.standard
        doubleTap = PlayerGestureAction(rawValue: d.string(forKey: "gesture_double_tap") ?? "") ?? .togglePlay
        longPress = PlayerGestureAction(rawValue: d.string(forKey: "gesture_long_press") ?? "") ?? .speedUpLongPress
        longPressVerticalDrag = PlayerGestureAction(rawValue: d.string(forKey: "gesture_lp_drag") ?? "") ?? .speedDrag
    }

    func set(_ action: PlayerGestureAction, for slot: String) {
        UserDefaults.standard.set(action.rawValue, forKey: slot)
        switch slot {
        case "gesture_double_tap": doubleTap = action
        case "gesture_long_press": longPress = action
        case "gesture_lp_drag": longPressVerticalDrag = action
        default: break
        }
    }

    func reset() {
        set(.togglePlay, for: "gesture_double_tap")
        set(.speedUpLongPress, for: "gesture_long_press")
        set(.speedDrag, for: "gesture_lp_drag")
    }
}
