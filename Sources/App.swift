import AppKit
import ServiceManagement

@main
struct QuotaBarMain {
    static func main() {
        if CommandLine.arguments.contains("--self-test") {
            exit(runSelfTest())
        }
        if CommandLine.arguments.contains("--once") {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let runner = OnceRunner()
            app.delegate = runner
            app.run()
            exit(EXIT_SUCCESS)
        }
        let already = NSRunningApplication.runningApplications(withBundleIdentifier: "com.hanzhang.quotabar")
        if already.count > 1 {
            exit(EXIT_SUCCESS)
        }
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }
}

final class OnceRunner: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Task {
            let readings = await UsageService().fetch()
            let payload = readings.map { reading -> [String: Any] in
                [
                    "name": reading.name,
                    "plan": reading.plan ?? "",
                    "error": reading.error ?? "",
                    "notes": reading.notes,
                    "meters": reading.meters.map { meter -> [String: Any] in
                        [
                            "label": meter.label,
                            "remaining": UsageFormat.percent(meter.remainingPercent),
                            "reset": meter.resetAt.map { UsageFormat.resetText($0) } ?? "",
                            "footnote": meter.footnote ?? "",
                        ]
                    },
                ]
            }
            if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
               let text = String(data: data, encoding: .utf8) {
                print(text)
            }
            NSApp.terminate(nil)
        }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var readings: [ProviderReading] = []
    private var updatedAt: Date?
    private var refreshing = false
    private var loginNote: String?
    private var timer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "用量"
        menu.delegate = self
        menu.autoenablesItems = false
        statusItem.menu = menu
        rebuildMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 180, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(machineDidWake),
            name: NSWorkspace.didWakeNotification,
            object: nil)
    }

    @objc private func machineDidWake() { refresh() }

    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
        if let updatedAt, Date().timeIntervalSince(updatedAt) > 30 {
            refresh()
        }
    }

    func refresh() {
        guard !refreshing else { return }
        refreshing = true
        if readings.isEmpty { statusItem.button?.title = "用量 …" }
        Task {
            let next = await UsageService().fetch()
            self.readings = next
            self.updatedAt = Date()
            self.refreshing = false
            self.applyTitle()
            if self.menu.highlightedItem == nil {
                self.rebuildMenu()
            }
        }
    }

    private func applyTitle() {
        guard let button = statusItem.button else { return }
        let title = NSMutableAttributedString()
        let nameFont = NSFont.systemFont(ofSize: 13)
        let valueFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)
        for (index, reading) in readings.enumerated() {
            if index > 0 {
                title.append(NSAttributedString(string: "   ", attributes: [.font: nameFont]))
            }
            for (pieceIndex, piece) in BarTitle.pieces(for: reading).enumerated() {
                if pieceIndex > 0 {
                    title.append(NSAttributedString(string: " ", attributes: [.font: nameFont]))
                }
                let color = piece.remaining.map(percentColor) ?? NSColor.labelColor
                let font = piece.remaining == nil ? nameFont : valueFont
                title.append(NSAttributedString(string: piece.text, attributes: [
                    .font: font,
                    .foregroundColor: color,
                ]))
            }
        }
        button.attributedTitle = title
        button.toolTip = BarTitle.tooltip(for: readings)
    }

    private func rebuildMenu() {
        menu.removeAllItems()
        if readings.isEmpty {
            menu.addItem(plain("正在读取用量…", color: .secondaryLabelColor))
        }
        for reading in readings {
            if menu.items.count > 0 { menu.addItem(.separator()) }
            menu.addItem(header(reading))
            if let error = reading.error, reading.meters.isEmpty {
                menu.addItem(plain(error, color: .systemOrange))
                continue
            }
            let sharedReset = sharedResetDate(reading.meters)
            for meter in reading.meters {
                menu.addItem(meterItem(meter))
                if sharedReset == nil, let reset = meter.resetAt {
                    menu.addItem(plain(UsageFormat.resetText(reset), color: .secondaryLabelColor))
                }
            }
            for note in reading.notes {
                menu.addItem(plain(note, color: .secondaryLabelColor))
            }
            if let sharedReset {
                menu.addItem(plain(UsageFormat.resetText(sharedReset), color: .secondaryLabelColor))
            }
        }
        menu.addItem(.separator())
        if let updatedAt {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "zh_CN")
            formatter.dateFormat = "HH:mm"
            menu.addItem(plain("更新于 \(formatter.string(from: updatedAt))", color: .tertiaryLabelColor))
        }
        if let loginNote {
            menu.addItem(plain(loginNote, color: .systemOrange))
        }
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(refreshClicked), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)
        let loginItem = NSMenuItem(title: "登录时打开", action: #selector(toggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(loginItem)
        let quitItem = NSMenuItem(title: "退出", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)
    }

    private func header(_ reading: ProviderReading) -> NSMenuItem {
        let text = NSMutableAttributedString(string: reading.name, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: NSColor.labelColor,
        ])
        if let plan = reading.plan, !plan.lowercased().contains(reading.name.lowercased()) {
            text.append(NSAttributedString(string: "   \(plan)", attributes: [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        let item = NSMenuItem()
        item.attributedTitle = text
        item.isEnabled = false
        return item
    }

    private func meterItem(_ meter: Meter) -> NSMenuItem {
        let font = NSFont.systemFont(ofSize: 13)
        let paragraph = NSMutableParagraphStyle()
        paragraph.tabStops = [
            NSTextTab(textAlignment: .left, location: 78),
            NSTextTab(textAlignment: .right, location: 168),
        ]
        let text = NSMutableAttributedString()
        let base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph, .foregroundColor: NSColor.labelColor]
        text.append(NSAttributedString(string: meter.label + "\t剩余\t", attributes: base))
        text.append(NSAttributedString(string: UsageFormat.percent(meter.remainingPercent), attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .semibold),
            .paragraphStyle: paragraph,
            .foregroundColor: percentColor(meter.remainingPercent),
        ]))
        if let footnote = meter.footnote {
            text.append(NSAttributedString(string: "  " + footnote, attributes: [
                .font: font,
                .foregroundColor: NSColor.secondaryLabelColor,
            ]))
        }
        let item = NSMenuItem()
        item.attributedTitle = text
        item.isEnabled = false
        return item
    }

    private func plain(_ string: String, color: NSColor) -> NSMenuItem {
        let item = NSMenuItem()
        item.attributedTitle = NSAttributedString(string: string, attributes: [
            .font: NSFont.systemFont(ofSize: 12),
            .foregroundColor: color,
        ])
        item.isEnabled = false
        return item
    }

    private func sharedResetDate(_ meters: [Meter]) -> Date? {
        let dates = meters.compactMap(\.resetAt)
        guard let first = dates.first, dates.count == meters.count else { return nil }
        let same = dates.allSatisfy { abs($0.timeIntervalSince(first)) < 1 }
        return same ? first : nil
    }

    private func percentColor(_ remaining: Double) -> NSColor {
        if remaining < 15 { return .systemRed }
        if remaining < 40 { return .systemOrange }
        return .labelColor
    }

    @objc private func refreshClicked() { refresh() }

    @objc private func toggleLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
                loginNote = nil
            } else {
                try SMAppService.mainApp.register()
                loginNote = SMAppService.mainApp.status == .requiresApproval
                    ? "请到系统设置 → 通用 → 登录项里允许「AI 用量」"
                    : nil
            }
        } catch {
            loginNote = "没能修改登录项"
        }
        rebuildMenu()
    }

    @objc private func quit() { NSApp.terminate(nil) }
}
