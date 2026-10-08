import AppKit
import Combine

/// 菜单栏图标要表达的状态。
///
/// 菜单栏空间很紧张，所以不在图标旁边写文字，而是整枚换图标：
/// 就绪 / 处理中 / 完成 / 注意 / 失败 / 没权限。
/// 具体文字放到 tooltip 和菜单第一项里。
enum StatusIconState {
    case idle
    case busy
    case success
    case warning
    case failure
    case noPermission

    var symbolName: String {
        switch self {
        case .idle: return "rectangle.3.group"
        case .busy: return "hourglass"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .failure: return "xmark.circle"
        case .noPermission: return "hand.raised"
        }
    }

    var summary: String {
        switch self {
        case .idle: return "就绪"
        case .busy: return "正在处理"
        case .success: return "完成"
        case .warning: return "需要注意"
        case .failure: return "失败"
        case .noPermission: return "缺少辅助功能权限"
        }
    }
}

/// 菜单栏图标 + 下拉菜单
final class StatusBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let menu = NSMenu()
    private weak var controller: AppController?

    init(controller: AppController) {
        self.controller = controller
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.toolTip = "WindowSnap · 窗口布局记忆"

        menu.delegate = self
        statusItem.menu = menu
    }

    // MARK: - 菜单

    func rebuildMenu() {
        // 菜单内容是按需构建的（menuNeedsUpdate），这里只处理菜单栏图标状态
        if controller?.isRestoring == true {
            showBusy("正在恢复…")
        } else if state == .busy {
            refreshIdleState()
        }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        guard let controller else { return }
        let store = controller.store
        let settings = controller.settings

        let header = NSMenuItem(title: "WindowSnap", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if lastMessage.isEmpty == false {
            let result = NSMenuItem(title: "上次：\(lastMessage)", action: nil, keyEquivalent: "")
            result.isEnabled = false
            menu.addItem(result)
        }

        if controller.hasPermission == false {
            let warning = NSMenuItem(title: "⚠️ 需要辅助功能权限（点这里去开启）",
                                     action: #selector(grantPermission), keyEquivalent: "")
            warning.target = self
            menu.addItem(warning)
        }

        menu.addItem(.separator())

        // ---- 恢复布局（所有保存的布局都收进这个展开菜单）
        let restoreItem = NSMenuItem(title: "恢复布局", action: #selector(restoreDefault), keyEquivalent: "")
        restoreItem.target = self
        restoreItem.isEnabled = store.layouts.isEmpty == false && controller.isRestoring == false
        applyHotKey(settings.hotKey(for: .restoreLayout), to: restoreItem)
        let restoreMenu = NSMenu()
        if store.layouts.isEmpty {
            let empty = NSMenuItem(title: "还没有保存过布局", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            restoreMenu.addItem(empty)
        }
        for layout in store.layouts {
            let item = NSMenuItem(title: title(for: layout), action: #selector(restoreLayout(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = layout.id.uuidString
            item.toolTip = layout.appSummary
            applyHotKey(layout.hotKey, to: item)
            if controller.isRestoring { item.isEnabled = false }
            restoreMenu.addItem(item)
        }
        restoreItem.submenu = restoreMenu
        menu.addItem(restoreItem)

        menu.addItem(.separator())

        // ---- 三个保存动作
        let saveCurrent = NSMenuItem(title: "保存当前窗口布局", action: nil, keyEquivalent: "")
        saveCurrent.submenu = makeSaveMenu(newTitle: "新建布局…",
                                          newAction: #selector(saveCurrentWindowNew),
                                          intoAction: #selector(saveCurrentWindowInto(_:)))
        saveCurrent.isEnabled = controller.isRestoring == false
        applyHotKey(settings.hotKey(for: .saveCurrentWindow), to: saveCurrent)
        menu.addItem(saveCurrent)

        let savePartial = NSMenuItem(title: "保存部分窗口布局", action: nil, keyEquivalent: "")
        savePartial.submenu = makeSaveMenu(newTitle: "新建布局…",
                                          newAction: #selector(savePartialNew),
                                          intoAction: #selector(savePartialInto(_:)))
        savePartial.isEnabled = controller.isRestoring == false
        applyHotKey(settings.hotKey(for: .savePartialWindows), to: savePartial)
        menu.addItem(savePartial)

        let saveAll = NSMenuItem(title: "保存所有窗口布局", action: nil, keyEquivalent: "")
        saveAll.submenu = makeSaveMenu(newTitle: "新建布局…",
                                      newAction: #selector(saveAllNew),
                                      intoAction: #selector(saveAllInto(_:)))
        saveAll.isEnabled = controller.isRestoring == false
        applyHotKey(settings.hotKey(for: .saveAllWindows), to: saveAll)
        menu.addItem(saveAll)

        if store.layouts.isEmpty == false {
            menu.addItem(.separator())

            // 「更新布局」放在「管理布局」里，主菜单不再单列一遍
            let manageItem = NSMenuItem(title: "管理布局", action: nil, keyEquivalent: "")
            let manageMenu = NSMenu()
            for layout in store.layouts {
                let item = NSMenuItem(title: layout.displayName, action: nil, keyEquivalent: "")
                let sub = NSMenu()
                sub.addItem(menuItem("编辑布局…", #selector(editLayout(_:)), layout.id.uuidString))
                sub.addItem(menuItem("更新布局", #selector(updateLayout(_:)), layout.id.uuidString))
                sub.addItem(menuItem("重命名…", #selector(renameLayout(_:)), layout.id.uuidString))
                sub.addItem(menuItem("复制一份", #selector(duplicateLayout(_:)), layout.id.uuidString))
                sub.addItem(.separator())
                sub.addItem(menuItem("删除…", #selector(deleteLayout(_:)), layout.id.uuidString))
                item.submenu = sub
                manageMenu.addItem(item)
            }
            manageItem.submenu = manageMenu
            menu.addItem(manageItem)
        }

        menu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "设置…", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        let logItem = NSMenuItem(title: "打开日志文件夹", action: #selector(openLogs), keyEquivalent: "")
        logItem.target = self
        menu.addItem(logItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "退出 WindowSnap", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    /// 构造「保存到…」的子菜单：先列已有布局，「新建布局…」永远放最下面
    private func makeSaveMenu(newTitle: String, newAction: Selector, intoAction: Selector) -> NSMenu {
        let submenu = NSMenu()
        let newItem = NSMenuItem(title: newTitle, action: newAction, keyEquivalent: "")
        newItem.target = self

        let layouts = controller?.store.layouts ?? []
        guard layouts.isEmpty == false else {
            submenu.addItem(newItem)
            return submenu
        }

        for layout in layouts {
            let item = NSMenuItem(title: layout.displayName, action: intoAction, keyEquivalent: "")
            item.target = self
            item.representedObject = layout.id.uuidString
            item.toolTip = "覆盖「\(layout.displayName)」（原本有 \(layout.windows.count) 个窗口）"
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        submenu.addItem(newItem)
        return submenu
    }

    /// 把热键显示成菜单右侧的标准样式
    private func applyHotKey(_ spec: HotKeySpec?, to item: NSMenuItem) {
        guard let spec, let equivalent = spec.keyEquivalent else { return }
        item.keyEquivalent = equivalent
        item.keyEquivalentModifierMask = HotKeyKeys.modifierFlags(from: spec.carbonModifiers)
    }


    private func title(for layout: Layout) -> String {
        var text = layout.name
        text += "（\(layout.windows.count) 个窗口）"
        if let hotKey = layout.hotKey {
            text += "   \(hotKey.display)"
        }
        return text
    }

    private func menuItem(_ title: String, _ action: Selector, _ id: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = id
        return item
    }

    /// 以编程方式弹出菜单（「恢复布局」没有历史可恢复时，让用户直接挑）
    func openMenu() {
        DispatchQueue.main.async { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    // MARK: - 菜单栏状态图标

    private(set) var state: StatusIconState = .idle
    private(set) var lastMessage = ""
    private var stateResetItem: DispatchWorkItem?

    /// 切换状态图标。`revertAfter` 有值时，过一会儿自动退回「就绪 / 没权限」。
    func setState(_ newState: StatusIconState, message: String? = nil, revertAfter: TimeInterval? = nil) {
        state = newState
        if let message { lastMessage = message }
        applyIcon()

        stateResetItem?.cancel()
        guard let revertAfter else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.state = self.idleState
            self.applyIcon()
        }
        stateResetItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + revertAfter, execute: work)
    }

    /// 空闲时应该显示什么：有权限就是正常图标，没权限就一直提示
    var idleState: StatusIconState {
        (controller?.hasPermission ?? true) ? .idle : .noPermission
    }

    func refreshIdleState() {
        setState(idleState)
    }

    /// 处理中（沙漏）。正常由后续结果来收尾；
    /// 这里再挂一个 60 秒的兜底，万一哪条分支没走到收尾，也不会永远停在沙漏上。
    func showBusy(_ message: String, timeout: TimeInterval = 60) {
        setState(.busy, message: message, revertAfter: timeout)
    }

    /// 一次性结果提示
    func flash(_ message: String,
               state newState: StatusIconState = .success,
               duration: TimeInterval = 4) {
        setState(newState, message: message, revertAfter: duration)
    }

    private func applyIcon() {
        let image = NSImage(systemSymbolName: state.symbolName, accessibilityDescription: "WindowSnap")
            ?? NSImage(systemSymbolName: "rectangle.3.group", accessibilityDescription: "WindowSnap")
        image?.isTemplate = true
        guard let button = statusItem.button else { return }
        button.image = image
        button.title = ""
        // 注意：toolTip 只在 init 里设一次，这里绝对不要动它。
        // 状态一变就改 toolTip 的话，AppKit 会跟着重新弹一次提示框，
        // 扫描 / 恢复期间状态一直在变，那个框就会一直挂在那儿不消失。
    }

    // MARK: - 动作

    @objc private func restoreLayout(_ sender: NSMenuItem) {
        guard let layout = layout(from: sender) else { return }
        controller?.restore(layout: layout)
    }

    @objc private func updateLayout(_ sender: NSMenuItem) {
        guard let layout = layout(from: sender) else { return }
        controller?.updateLayout(layout)
    }

    @objc private func renameLayout(_ sender: NSMenuItem) {
        guard let layout = layout(from: sender) else { return }
        controller?.renameLayout(layout)
    }

    @objc private func duplicateLayout(_ sender: NSMenuItem) {
        guard let layout = layout(from: sender) else { return }
        controller?.duplicateLayout(layout)
    }

    @objc private func deleteLayout(_ sender: NSMenuItem) {
        guard let layout = layout(from: sender) else { return }
        controller?.deleteLayout(layout)
    }

    /// 点「恢复布局」本身：恢复最近用过的那个布局
    @objc private func restoreDefault() {
        controller?.restoreLastUsedLayout()
    }

    @objc private func saveCurrentWindowNew() {
        controller?.saveCurrentWindowLayout()
    }

    @objc private func savePartialNew() {
        controller?.savePartialWindowsLayout()
    }

    @objc private func saveAllNew() {
        controller?.saveAllWindowsLayout()
    }

    @objc private func saveCurrentWindowInto(_ sender: NSMenuItem) {
        guard let layout = layout(from: sender) else { return }
        controller?.saveCurrentWindow(into: layout)
    }

    @objc private func savePartialInto(_ sender: NSMenuItem) {
        guard let layout = layout(from: sender) else { return }
        controller?.savePartialWindows(into: layout)
    }

    @objc private func saveAllInto(_ sender: NSMenuItem) {
        guard let layout = layout(from: sender) else { return }
        controller?.saveAllWindows(into: layout)
    }

    @objc private func openSettings() {
        controller?.openSettings()
    }

    @objc private func editLayout(_ sender: NSMenuItem) {
        guard let idString = sender.representedObject as? String,
              let layoutID = UUID(uuidString: idString) else { return }
        controller?.openSettings(tab: .layouts, layoutID: layoutID)
    }

    @objc private func grantPermission() {
        controller?.requestPermission()
    }

    @objc private func openLogs() {
        NSWorkspace.shared.selectFile(Log.fileURL.path, inFileViewerRootedAtPath: Log.directory.path)
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func layout(from sender: NSMenuItem) -> Layout? {
        guard let idString = sender.representedObject as? String, let uuid = UUID(uuidString: idString) else { return nil }
        return controller?.store.layout(id: uuid)
    }
}
