import AppKit
import CoreGraphics

/// 一块显示器的信息
struct DisplayInfo: Hashable {
    var id: CGDirectDisplayID
    var index: Int
    var name: String
    /// 完整矩形（Quartz 全局坐标，左上原点）
    var frame: CGRect
    /// 去掉菜单栏/Dock 之后的可用矩形（Quartz 全局坐标）
    var visibleFrame: CGRect
}

/// 坐标系转换与显示器解析。
///
/// 三个坐标系要拎清楚：
/// - AX / CGWindowList：全局坐标，原点在**主屏左上角**，y 向下（Quartz）
/// - NSScreen.frame：全局坐标，原点在**主屏左下角**，y 向上（Cocoa）
/// - 窗口相对屏幕的坐标：自己算
enum ScreenGeometry {

    static var mainDisplayID: CGDirectDisplayID { CGMainDisplayID() }

    /// 主屏高度，用于 Cocoa <-> Quartz 转换
    static var primaryHeight: CGFloat { CGDisplayBounds(CGMainDisplayID()).height }

    static func cocoaToQuartz(_ rect: NSRect) -> CGRect {
        CGRect(x: rect.origin.x,
               y: primaryHeight - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }

    static func quartzToCocoa(_ rect: CGRect) -> NSRect {
        NSRect(x: rect.origin.x,
               y: primaryHeight - rect.origin.y - rect.height,
               width: rect.width,
               height: rect.height)
    }

    static func displayID(of screen: NSScreen) -> CGDirectDisplayID {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        if let number = screen.deviceDescription[key] as? NSNumber {
            return CGDirectDisplayID(number.uint32Value)
        }
        return CGMainDisplayID()
    }

    private static let displayCacheLock = NSLock()
    private static var cachedDisplays: [DisplayInfo] = []
    private static var cachedAt = Date.distantPast

    /// 显示器列表。
    ///
    /// NSScreen 查询并不便宜，而扫描 / 恢复一个布局会问它几百次，
    /// 所以这里加一层短 TTL 缓存：一次操作内拿到的是同一份快照，
    /// 又不必几百次重复查询。
    static var currentDisplays: [DisplayInfo] {
        displayCacheLock.lock()
        defer { displayCacheLock.unlock() }
        if cachedDisplays.isEmpty == false, Date().timeIntervalSince(cachedAt) < 2.0 {
            return cachedDisplays
        }
        let displays = NSScreen.screens.enumerated().map { index, screen -> DisplayInfo in
            let id = displayID(of: screen)
            return DisplayInfo(id: id,
                               index: index,
                               name: screen.localizedName,
                               frame: CGDisplayBounds(id),
                               visibleFrame: cocoaToQuartz(screen.visibleFrame))
        }
        cachedDisplays = displays
        cachedAt = Date()
        return displays
    }

    /// 显示器配置变了就清掉缓存
    static func invalidateDisplayCache() {
        displayCacheLock.lock()
        defer { displayCacheLock.unlock() }
        cachedDisplays = []
        cachedAt = .distantPast
    }

    static func display(withID id: CGDirectDisplayID) -> DisplayInfo? {
        currentDisplays.first { $0.id == id }
    }

    /// 找出矩形主要落在哪块显示器上
    static func display(containing rect: CGRect) -> DisplayInfo? {
        display(containing: rect, in: currentDisplays)
    }

    /// 在指定的一组显示器里找主要落点
    static func display(containing rect: CGRect, in displays: [DisplayInfo]) -> DisplayInfo? {
        var best: DisplayInfo?
        var bestArea: CGFloat = 0
        for display in displays {
            let inter = display.frame.intersection(rect)
            guard !inter.isNull else { continue }
            let area = inter.width * inter.height
            if area > bestArea {
                bestArea = area
                best = display
            }
        }
        return best ?? displays.first
    }

    /// 把窗口限制在显示器的可用区域内（至少保证标题栏可见）
    static func clampWithinVisibleArea(_ frame: CGRect, display: DisplayInfo) -> CGRect {
        let area = display.visibleFrame.insetBy(dx: -8, dy: -8)
        var rect = frame
        if rect.width > area.width { rect.size.width = area.width }
        if rect.height > area.height { rect.size.height = area.height }
        if rect.minY < area.minY { rect.origin.y = area.minY }
        if rect.maxY > area.maxY { rect.origin.y = area.maxY - rect.height }
        if rect.minX < area.minX { rect.origin.x = area.minX }
        if rect.maxX > area.maxX { rect.origin.x = area.maxX - rect.width }
        return rect
    }

    /// 为快照算出「现在应该放在哪儿」
    ///
    /// 策略：
    /// 1. 同款显示器还在 → 直接用保存的绝对坐标（最精确）
    /// 2. 显示器没了/换了 → 按序号找一块屏，用归一化坐标投影过去
    /// 3. 完全对不上 → 投到主屏
    static func resolveTarget(for snapshot: WindowSnapshot) -> (frame: CGRect, display: DisplayInfo, remapped: Bool) {
        let displays = currentDisplays
        let saved = snapshot.frame.cgRect

        guard let primary = displays.first else {
            return (saved, DisplayInfo(id: mainDisplayID, index: 0, name: "主屏",
                                       frame: CGDisplayBounds(mainDisplayID),
                                       visibleFrame: CGDisplayBounds(mainDisplayID)), true)
        }

        // 1. 原来那块屏还在
        if let same = displays.first(where: { $0.id == snapshot.displayID }) {
            let visible = same.frame.insetBy(dx: -40, dy: -40)
            if saved.intersects(visible) {
                let frame = (saved.width >= 80 && saved.height >= 60)
                    ? clampWithinVisibleArea(saved, display: same)
                    : saved
                return (frame, same, false)
            }
            // 屏幕还在但窗口跑到屏幕外了（排列变了），退化成投影
            let projected = snapshot.relativeFrame.projected(onto: same.frame).cgRect
            return (clampWithinVisibleArea(projected, display: same), same, true)
        }

        // 2. 按序号找同位置的屏
        if snapshot.displayIndex >= 0, snapshot.displayIndex < displays.count {
            let target = displays[snapshot.displayIndex]
            let projected = snapshot.relativeFrame.projected(onto: target.frame).cgRect
            return (clampWithinVisibleArea(projected, display: target), target, true)
        }

        // 3. 投到主屏
        let projected = snapshot.relativeFrame.projected(onto: primary.frame).cgRect
        return (clampWithinVisibleArea(projected, display: primary), primary, true)
    }
}
