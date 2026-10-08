import Foundation
import AppKit
import CoreGraphics

struct ScanOptions {
    var includeMinimized = true
    var includeDialogs = true
    var excludedBundleIDs: Set<String> = []
    /// 太小的窗口（浮窗、提示条）不记录
    var minimumWidth: CGFloat = 60
    var minimumHeight: CGFloat = 40
}

/// 扫描当前所有普通应用的窗口，生成快照
enum WindowScanner {

    static func snapshot(options: ScanOptions = ScanOptions()) -> [WindowSnapshot] {
        var zOrder = windowZOrder()
        var result: [WindowSnapshot] = []
        let myPID = ProcessInfo.processInfo.processIdentifier

        for app in NSWorkspace.shared.runningApplications {
            guard app.activationPolicy == .regular,
                  let bundleID = app.bundleIdentifier,
                  app.processIdentifier != myPID,
                  !options.excludedBundleIDs.contains(bundleID) else { continue }

            let element = AX.application(for: app.processIdentifier)
            AX.limitMessagingTimeout(element, seconds: 1.0)

            let axWindows = AX.windows(ofApplication: element)
            guard !axWindows.isEmpty else { continue }

            for (index, window) in axWindows.enumerated() {
                AX.limitMessagingTimeout(window, seconds: 1.0)

                guard let role = AX.string(window, AXAttr.role), role == AXRole.window else { continue }
                let subrole = AX.string(window, AXAttr.subrole) ?? ""
                if subrole == AXRole.sheet { continue }
                if !options.includeDialogs && subrole == AXRole.dialog { continue }

                guard let rect = AX.frame(of: window) else { continue }

                let minimized = AX.bool(window, AXAttr.minimized) ?? false
                if minimized && !options.includeMinimized { continue }
                if !minimized && (rect.width < options.minimumWidth || rect.height < options.minimumHeight) { continue }

                let display = ScreenGeometry.display(containing: rect)
                let displayFrame = display?.frame ?? CGDisplayBounds(CGMainDisplayID())

                let snapshot = WindowSnapshot(
                    bundleID: bundleID,
                    appName: app.localizedName ?? bundleID,
                    title: AX.string(window, AXAttr.title) ?? "",
                    role: role,
                    subrole: subrole,
                    frame: Frame(rect),
                    displayID: display?.id ?? CGMainDisplayID(),
                    displayIndex: display?.index ?? 0,
                    displayName: display?.name ?? "主显示器",
                    displayFrame: Frame(displayFrame),
                    relativeFrame: Frame(rect).relative(to: displayFrame),
                    isMinimized: minimized,
                    isFullScreen: AX.bool(window, AXAttr.fullScreen) ?? false,
                    zIndex: zOrder.value(pid: app.processIdentifier, rect: rect, fallback: index)
                )
                result.append(snapshot)
            }
        }

        return result.sorted { $0.zIndex < $1.zIndex }
    }

    // MARK: - 单个窗口

    /// 只取「当前正在用的那个窗口」：最前面那个应用的焦点窗口
    static func snapshotFrontmostWindow(options: ScanOptions = ScanOptions()) -> WindowSnapshot? {
        guard let app = NSWorkspace.shared.frontmostApplication,
              let bundleID = app.bundleIdentifier,
              app.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              options.excludedBundleIDs.contains(bundleID) == false else { return nil }

        let appElement = AX.application(for: app.processIdentifier)
        AX.limitMessagingTimeout(appElement, seconds: 1.0)

        var target = AX.elementAttribute(appElement, AXAttr.focusedWindow)
        if target == nil {
            target = AX.windows(ofApplication: appElement).first
        }
        guard let window = target else { return nil }
        return makeSnapshot(window: window, app: app, bundleID: bundleID, zIndex: 0, options: options)
    }

    /// 从 AX 窗口元素造一条快照。「扫描全部」和「保存当前窗口」共用这套字段。
    static func makeSnapshot(window: AXUIElement,
                             app: NSRunningApplication,
                             bundleID: String,
                             zIndex: Int,
                             options: ScanOptions) -> WindowSnapshot? {
        AX.limitMessagingTimeout(window, seconds: 1.0)
        guard let role = AX.string(window, AXAttr.role), role == AXRole.window else { return nil }
        guard let rect = AX.frame(of: window) else { return nil }

        let minimized = AX.bool(window, AXAttr.minimized) ?? false
        if minimized == false && (rect.width < options.minimumWidth || rect.height < options.minimumHeight) {
            return nil
        }

        let display = ScreenGeometry.display(containing: rect)
        let displayFrame = display?.frame ?? CGDisplayBounds(CGMainDisplayID())

        return WindowSnapshot(
            bundleID: bundleID,
            appName: app.localizedName ?? bundleID,
            title: AX.string(window, AXAttr.title) ?? "",
            role: role,
            subrole: AX.string(window, AXAttr.subrole) ?? "",
            frame: Frame(rect),
            displayID: display?.id ?? CGMainDisplayID(),
            displayIndex: display?.index ?? 0,
            displayName: display?.name ?? "主显示器",
            displayFrame: Frame(displayFrame),
            relativeFrame: Frame(rect).relative(to: displayFrame),
            isMinimized: minimized,
            isFullScreen: AX.bool(window, AXAttr.fullScreen) ?? false,
            zIndex: zIndex)
    }

    // MARK: - 前后顺序

    /// CGWindowList 是「前面优先」的顺序，用它给窗口排个 z 序
    private struct ZOrderTable {
        private var entries: [(pid: pid_t, rect: CGRect, used: Bool)]

        init(_ list: [(pid: pid_t, rect: CGRect)]) {
            entries = list.map { (pid: $0.pid, rect: $0.rect, used: false) }
        }

        mutating func value(pid: pid_t, rect: CGRect, fallback: Int) -> Int {
            for i in entries.indices {
                guard !entries[i].used, entries[i].pid == pid else { continue }
                let candidate = entries[i].rect
                if abs(candidate.minX - rect.minX) <= 2,
                   abs(candidate.minY - rect.minY) <= 2,
                   abs(candidate.width - rect.width) <= 2,
                   abs(candidate.height - rect.height) <= 2 {
                    entries[i].used = true
                    return i
                }
            }
            return 1000 + fallback
        }
    }

    private static func windowZOrder() -> ZOrderTable {
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let raw = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]] else {
            return ZOrderTable([])
        }
        var list: [(pid: pid_t, rect: CGRect)] = []
        for info in raw {
            guard let layer = (info[kCGWindowLayer as String] as? NSNumber)?.intValue, layer == 0 else { continue }
            guard let pidNumber = info[kCGWindowOwnerPID as String] as? NSNumber else { continue }
            guard let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let rect = decode(bounds) else { continue }
            list.append((pid: pid_t(pidNumber.intValue), rect: rect))
        }
        return ZOrderTable(list)
    }

    private static func decode(_ dictionary: [String: Any]) -> CGRect? {
        guard let x = (dictionary["X"] as? NSNumber)?.doubleValue,
              let y = (dictionary["Y"] as? NSNumber)?.doubleValue,
              let w = (dictionary["Width"] as? NSNumber)?.doubleValue,
              let h = (dictionary["Height"] as? NSNumber)?.doubleValue else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
}
