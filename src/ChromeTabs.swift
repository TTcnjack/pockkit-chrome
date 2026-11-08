import AppKit
import PockKit
import ObjectiveC
import ApplicationServices

// MARK: - Chrome 桥接（Accessibility / AX）

enum ChromeBridge {

    static let bundleID = "com.google.Chrome"

    struct Snapshot {
        let titles: [String]
        let activeIndex: Int   // 0-based，-1 表示未知
    }

    /// 用 AX 读 Chrome「标签页」菜单里的标签项。
    static func fetch() -> (snapshot: Snapshot?, error: String?) {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else {
            return (nil, "Chrome 未运行")
        }
        guard let items = tabMenuItems(pid: app.processIdentifier) else {
            return (nil, "读不到菜单")
        }
        var titles: [String] = []
        var active = -1
        for item in items {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef)
            let title = titleRef as? String ?? ""
            if title.isEmpty { continue }
            titles.append(title)
            var markRef: CFTypeRef?
            if AXUIElementCopyAttributeValue(item, kAXMenuItemMarkCharAttribute as CFString, &markRef) == .success,
               let mark = markRef as? String, !mark.isEmpty {
                active = titles.count - 1
            }
        }
        return (Snapshot(titles: titles, activeIndex: active), nil)
    }

    /// 切换标签：对「标签页」菜单里第 index 个标签项发 AXPress。
    @discardableResult
    static func activateTab(at index: Int) -> Bool {
        guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first else { return false }
        guard let items = tabMenuItems(pid: app.processIdentifier) else { return false }
        var tabs: [AXUIElement] = []
        for item in items {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef)
            if let t = titleRef as? String, !t.isEmpty { tabs.append(item) }
        }
        guard index >= 0 && index < tabs.count else { return false }
        return AXUIElementPerformAction(tabs[index], kAXPressAction as CFString) == .success
    }

    /// 返回「标签页」菜单里「搜索标签页」之后的非空菜单项（即标签列表）。
    private static func tabMenuItems(pid: pid_t) -> [AXUIElement]? {
        let axApp = AXUIElementCreateApplication(pid)
        var menuBarRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXMenuBarAttribute as CFString, &menuBarRef) == .success,
              let menuBarRef = menuBarRef else { return nil }
        let menuBar = menuBarRef as! AXUIElement
        var childrenRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menuBar, kAXChildrenAttribute as CFString, &childrenRef) == .success,
              let children = childrenRef as? [AXUIElement] else { return nil }

        var tabsItem: AXUIElement?
        for c in children {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(c, kAXTitleAttribute as CFString, &titleRef)
            if let t = titleRef as? String, t.contains("标签页") || t.lowercased().contains("tabs") {
                tabsItem = c; break
            }
        }
        guard let tabsItem = tabsItem else { return nil }

        var menuRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(tabsItem, kAXChildrenAttribute as CFString, &menuRef) == .success,
              let menus = menuRef as? [AXUIElement], let menu = menus.first else { return nil }
        var itemsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(menu, kAXChildrenAttribute as CFString, &itemsRef) == .success,
              let items = itemsRef as? [AXUIElement] else { return nil }

        var result: [AXUIElement] = []
        var seenSearch = false
        for item in items {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(item, kAXTitleAttribute as CFString, &titleRef)
            let title = titleRef as? String ?? ""
            if title.isEmpty { continue }
            if title.contains("搜索标签页") || title.lowercased().contains("search tabs") {
                seenSearch = true
                continue
            }
            if seenSearch {
                result.append(item)
            }
        }
        return result
    }
}

// MARK: - 单个标签 item

final class ChromeTabItemView: NSScrubberItemView {

    private let titleLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6

        titleLabel.font = NSFont.systemFont(ofSize: 13)
        titleLabel.textColor = .white
        titleLabel.lineBreakMode = .byTruncatingTail
        titleLabel.alignment = .left
        titleLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(titleLabel)
        NSLayoutConstraint.activate([
            titleLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            titleLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            titleLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(title: String, active: Bool) {
        titleLabel.stringValue = title
        layer?.backgroundColor = (active ? NSColor.darkGray : NSColor.clear).cgColor
    }
}

// MARK: - 非 Chrome 时的占位（Chrome 图标 + 可选状态，点击唤起 Chrome）

final class ChromePlaceholderView: NSView {

    var onTap: (() -> Void)?

    private let iconView = NSImageView()
    private let statusLabel = NSTextField(labelWithString: "")

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 6
        layer?.backgroundColor = NSColor.darkGray.cgColor

        // Chrome 图标（NSImageView 不拦截点击，手势能落到本 view）
        iconView.imageScaling = .scaleProportionallyDown
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)
        NSLayoutConstraint.activate([
            iconView.centerXAnchor.constraint(equalTo: centerXAnchor),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -2),
            iconView.widthAnchor.constraint(equalToConstant: 20),
            iconView.heightAnchor.constraint(equalToConstant: 20),
        ])

        // 状态文字（诊断用：权限失败时显示「需授权」）
        statusLabel.font = NSFont.systemFont(ofSize: 9, weight: .semibold)
        statusLabel.textColor = .systemYellow
        statusLabel.alignment = .center
        statusLabel.lineBreakMode = .byClipping
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        statusLabel.isHidden = true
        addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            statusLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            statusLabel.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -1),
        ])

        let click = NSClickGestureRecognizer(target: self, action: #selector(handleTap))
        click.allowedTouchTypes = .direct
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setChromeIcon() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ChromeBridge.bundleID) {
            iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        }
    }

    func showStatus(_ text: String?) {
        let t = text ?? ""
        statusLabel.stringValue = t
        statusLabel.isHidden = t.isEmpty
    }

    @objc private func handleTap() { onTap?() }
}

// MARK: - 主视图：横向标签列表（NSScrubber）+ 占位

final class ChromeTabsView: NSView, NSScrubberDataSource, NSScrubberDelegate {

    var onSelect: ((Int) -> Void)?

    private let scrubber = NSScrubber()
    private let placeholder = ChromePlaceholderView()

    private var titles: [String] = []
    private var activeIndex = 0

    private static let itemSize = NSSize(width: 132, height: 30)
    private static let listWidth: CGFloat = 340
    private static let placeholderWidth: CGFloat = 60

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupScrubber()
        setupPlaceholder()
        placeholder.setChromeIcon()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func setupScrubber() {
        let layout = NSScrubberFlowLayout()
        layout.itemSize = Self.itemSize
        layout.itemSpacing = 4
        scrubber.scrubberLayout = layout
        scrubber.dataSource = self
        scrubber.delegate = self
        scrubber.mode = .free
        scrubber.isContinuous = false
        scrubber.itemAlignment = .none
        scrubber.showsAdditionalContentIndicators = true
        scrubber.translatesAutoresizingMaskIntoConstraints = false
        addSubview(scrubber)
        NSLayoutConstraint.activate([
            scrubber.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrubber.trailingAnchor.constraint(equalTo: trailingAnchor),
            scrubber.topAnchor.constraint(equalTo: topAnchor),
            scrubber.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    private func setupPlaceholder() {
        placeholder.translatesAutoresizingMaskIntoConstraints = false
        placeholder.isHidden = true
        placeholder.onTap = { [weak self] in
            self?.launchChrome()
        }
        addSubview(placeholder)
        NSLayoutConstraint.activate([
            placeholder.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 2),
            placeholder.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            placeholder.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            placeholder.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2),
        ])
    }

    private func launchChrome() {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ChromeBridge.bundleID) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: config, completionHandler: nil)
        }
    }

    // MARK: 状态更新

    func show(titles: [String], activeIndex: Int) {
        self.titles = titles
        self.activeIndex = activeIndex
        placeholder.isHidden = true
        scrubber.isHidden = false
        scrubber.reloadData()
        if activeIndex >= 0 && activeIndex < titles.count {
            scrubber.scrollItem(at: activeIndex, to: .center)
        }
        invalidateIntrinsicContentSize()
    }

    func showPlaceholder(status: String? = nil) {
        if scrubber.isHidden {
            // 已处于占位态，只更新状态文字
            placeholder.showStatus(status)
            return
        }
        titles = []
        scrubber.isHidden = true
        placeholder.isHidden = false
        placeholder.showStatus(status)
        invalidateIntrinsicContentSize()
    }

    override var intrinsicContentSize: NSSize {
        if scrubber.isHidden {
            return NSSize(width: Self.placeholderWidth, height: 30)
        }
        return NSSize(width: Self.listWidth, height: 30)
    }

    // MARK: NSScrubberDataSource

    func numberOfItems(for scrubber: NSScrubber) -> Int {
        titles.count
    }

    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let item = ChromeTabItemView()
        item.configure(title: titles[index], active: index == activeIndex)
        return item
    }

    // MARK: NSScrubberDelegate

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt selectedIndex: Int) {
        scrubber.selectedIndex = -1
        guard selectedIndex >= 0 && selectedIndex < titles.count else { return }
        onSelect?(selectedIndex)
    }
}

// MARK: - 组件本体

@objc(ChromeTabs)
public class ChromeTabs: NSObject, PKWidget {

    public var identifier = NSTouchBarItem.Identifier("com.hwq.pock.ChromeTabs")
    public var customizationLabel: String = "Chrome 标签页"
    public var view: NSView!

    /// 「自定义 Pock」界面里的预览图：直接取 Chrome 的图标。
    /// 必须 @objc —— Pock 内置 PockKit 通过 ObjC 运行时调用这个 optional getter。
    @objc public var imageForCustomization: NSImage {
        if let chromePath = NSWorkspace.shared.urlForApplication(withBundleIdentifier: ChromeBridge.bundleID) {
            return NSWorkspace.shared.icon(forFile: chromePath.path)
        }
        return NSImage(named: NSImage.applicationIconName) ?? NSImage()
    }

    private let container = ChromeTabsView()
    private var observer: NSObjectProtocol?
    private var isChromeFrontmost = false
    private var currentFrontmostBundleID: String?
    private var lastSnapshot: ChromeBridge.Snapshot?

    public required override init() {
        super.init()
        view = container
        container.onSelect = { [weak self] idx in
            self?.activateTab(at: idx)
        }

        currentFrontmostBundleID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        observer = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.currentFrontmostBundleID = app?.bundleIdentifier
            self?.refreshFrontmost()
        }
        refreshFrontmost()
    }

    deinit {
        if let o = observer { NSWorkspace.shared.notificationCenter.removeObserver(o) }
    }

    // MARK: 生命周期

    public func viewWillAppear() {
        refreshFrontmost()
    }

    public func viewDidDisappear() {
        // 二级页显示时一级页的 view 会消失，但轮询要留着刷新二级页；deinit 时停。
    }

    // MARK: 前台检测

    private func refreshFrontmost() {
        let isChrome = currentFrontmostBundleID == ChromeBridge.bundleID
        isChromeFrontmost = isChrome
        if isChrome {
            reloadTabs()
            pushPageIfNeeded()
        } else {
            lastSnapshot = nil
            container.showPlaceholder(status: nil)
            popPageIfNeeded()
        }
    }

    // MARK: 二级页导航（最小验证）

    /// 反射 Pock 的导航栈：Pock.TouchBarHelper.mainNavigationController() → AppController.navigationController
    private var mainNav: PKTouchBarNavigationController? {
        guard let cls = objc_getClass("Pock.TouchBarHelper") as? NSObjectProtocol else { return nil }
        let sel = NSSelectorFromString("mainNavigationController")
        guard cls.responds(to: sel) else { return nil }
        return cls.perform(sel)?.takeUnretainedValue() as? PKTouchBarNavigationController
    }

    private var pageController: PKTouchBarController?
    private var pageDelegate: ChromePageDelegate?
    private var pageTouchBar: NSTouchBar?

    private func pushPageIfNeeded() {
        guard let nav = mainNav else { return }
        guard pageController == nil else { return }
        let page = PKTouchBarController()
        let tb = NSTouchBar()
        let del = ChromePageDelegate()
        del.onBack = { [weak self] in self?.dismissPage() }
        del.onSelectTab = { [weak self] idx in self?.activateTab(at: idx) }
        tb.delegate = del
        tb.defaultItemIdentifiers = [.chromePageBack, .chromePageTabs]
        // KVC 设 touchBar：不继承 PKTouchBarController，避免引用其 open-setter 符号
        page.setValue(tb, forKey: "touchBar")
        pageController = page
        pageDelegate = del
        pageTouchBar = tb
        nav.push(page)
        if let snap = lastSnapshot {
            pageDelegate?.update(titles: snap.titles, activeIndex: snap.activeIndex)
        }
    }

    private func dismissPage() {
        guard let nav = mainNav else { return }
        // 栈顶必须是我们 push 的二级页才能 pop；否则会把 Pock 主 Touch Bar 也 pop 掉
        guard let page = pageController, nav.visibleController === page else {
            pageController = nil
            pageDelegate = nil
            pageTouchBar = nil
            return
        }
        nav.popLastController()
        pageController = nil
        pageDelegate = nil
        pageTouchBar = nil
    }

    private func popPageIfNeeded() {
        dismissPage()
    }

    // MARK: 数据

    private func reloadTabs() {
        let result = ChromeBridge.fetch()
        if let snap = result.snapshot {
            if let last = lastSnapshot,
               last.titles == snap.titles, last.activeIndex == snap.activeIndex {
                pageDelegate?.update(titles: snap.titles, activeIndex: snap.activeIndex)
                return
            }
            lastSnapshot = snap
            container.show(titles: snap.titles, activeIndex: snap.activeIndex)
            pageDelegate?.update(titles: snap.titles, activeIndex: snap.activeIndex)
        } else {
            container.showPlaceholder(status: result.error)
            pageDelegate?.updateError(result.error)
        }
    }

    private func activateTab(at index: Int) {
        // 乐观更新：立即高亮用户点的标签；点击后不再回读（只在聚焦 Chrome 时确认）
        if let snap = lastSnapshot, index >= 0 && index < snap.titles.count {
            let optimistic = ChromeBridge.Snapshot(titles: snap.titles, activeIndex: index)
            lastSnapshot = optimistic
            container.show(titles: optimistic.titles, activeIndex: index)
            pageDelegate?.update(titles: optimistic.titles, activeIndex: index)
        }
        ChromeBridge.activateTab(at: index)
    }
}

// MARK: - 最小验证：二级页（返回按钮 + 静态文字）

/// 触控栏上的「返回」按钮：自绘 + .direct 触摸手势。
/// 普通 NSButton 在触控栏上收不到直接触摸，点不动。
final class ChromeBackButtonView: NSView {

    var onTap: (() -> Void)?
    private let title = "‹ 返回"

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let click = NSClickGestureRecognizer(target: self, action: #selector(tapped))
        click.allowedTouchTypes = .direct
        addGestureRecognizer(click)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 56, height: 30)
    }

    override func draw(_ dirtyRect: NSRect) {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 13),
            .foregroundColor: NSColor.white
        ]
        let size = (title as NSString).size(withAttributes: attrs)
        (title as NSString).draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                             y: (bounds.height - size.height) / 2),
                                 withAttributes: attrs)
    }

    @objc private func tapped() { onTap?() }
}

extension NSTouchBarItem.Identifier {
    static let chromePageBack  = NSTouchBarItem.Identifier("com.hwq.pock.ChromeTabs.pageBack")
    static let chromePageTabs  = NSTouchBarItem.Identifier("com.hwq.pock.ChromeTabs.pageTabs")
}

final class ChromePageDelegate: NSObject, NSTouchBarDelegate, NSScrubberDataSource, NSScrubberDelegate {

    var onBack: (() -> Void)?
    var onSelectTab: ((Int) -> Void)?

    private var titles: [String] = []
    private var activeIndex = -1
    private var scrubber: NSScrubber?

    /// 由 widget 读到真实标签后调用
    func update(titles: [String], activeIndex: Int) {
        self.titles = titles
        self.activeIndex = activeIndex
        scrubber?.reloadData()
        if activeIndex >= 0 && activeIndex < titles.count {
            scrubber?.scrollItem(at: activeIndex, to: .center)
        }
    }

    /// 读取失败（如未授权）时调用
    func updateError(_ text: String?) {
        self.titles = text.map { ["⚠️ \($0)"] } ?? []
        self.activeIndex = -1
        scrubber?.reloadData()
    }

    func touchBar(_ touchBar: NSTouchBar, makeItemForIdentifier identifier: NSTouchBarItem.Identifier) -> NSTouchBarItem? {
        switch identifier {
        case .chromePageBack:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let back = ChromeBackButtonView()
            back.onTap = { [weak self] in self?.onBack?() }
            item.view = back
            return item
        case .chromePageTabs:
            let item = NSCustomTouchBarItem(identifier: identifier)
            let scrubber = NSScrubber(frame: NSRect(x: 0, y: 0, width: 420, height: 30))
            let layout = NSScrubberFlowLayout()
            layout.itemSize = NSSize(width: 132, height: 30)
            layout.itemSpacing = 4
            scrubber.scrubberLayout = layout
            scrubber.dataSource = self
            scrubber.delegate = self
            scrubber.mode = .free
            scrubber.isContinuous = false
            scrubber.showsAdditionalContentIndicators = true
            self.scrubber = scrubber
            item.view = scrubber
            return item
        default:
            return nil
        }
    }

    // MARK: NSScrubberDataSource

    func numberOfItems(for scrubber: NSScrubber) -> Int {
        titles.count
    }

    func scrubber(_ scrubber: NSScrubber, viewForItemAt index: Int) -> NSScrubberItemView {
        let item = ChromeTabItemView()
        item.configure(title: titles[index], active: index == activeIndex)
        return item
    }

    // MARK: NSScrubberDelegate

    func scrubber(_ scrubber: NSScrubber, didSelectItemAt selectedIndex: Int) {
        scrubber.selectedIndex = -1
        onSelectTab?(selectedIndex)
    }
}
