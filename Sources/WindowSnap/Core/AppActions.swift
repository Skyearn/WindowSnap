import Foundation

/// 全局动作。这些快捷键是「功能」级别的，和某个具体布局无关。
enum AppAction: String, CaseIterable, Identifiable {
    case restoreLayout
    case saveCurrentWindow
    case savePartialWindows
    case saveAllWindows

    var id: String { rawValue }

    var title: String {
        switch self {
        case .restoreLayout: return "恢复布局"
        case .saveCurrentWindow: return "保存当前窗口布局"
        case .savePartialWindows: return "保存部分窗口布局"
        case .saveAllWindows: return "保存所有窗口布局"
        }
    }

    var symbol: String {
        switch self {
        case .restoreLayout: return "arrow.uturn.backward"
        case .saveCurrentWindow: return "macwindow"
        case .savePartialWindows: return "checklist"
        case .saveAllWindows: return "rectangle.3.group"
        }
    }

    var detail: String {
        switch self {
        case .restoreLayout:
            return "恢复最近用过的那个布局；没有用过的话会打开菜单让你挑"
        case .saveCurrentWindow:
            return "只把当前正在用的那个窗口（最前面应用的焦点窗口）存成一个布局"
        case .savePartialWindows:
            return "打开窗口列表，勾选需要的几个窗口存成布局"
        case .saveAllWindows:
            return "把当前所有窗口存成一个布局"
        }
    }

    /// 只有「恢复布局」有默认快捷键，其他都留空由用户自己设
    var defaultHotKey: HotKeySpec? {
        switch self {
        case .restoreLayout: return .defaultRestore
        default: return nil
        }
    }
}
