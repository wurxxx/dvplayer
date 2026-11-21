import AppKit
import UniformTypeIdentifiers

/// 打开蓝光原盘的入口：选 ISO → 挂载读标题 → 选一个 → 交给播放器。
@MainActor
enum DiscUI {
    static func chooseAndPlay() {
        let panel = NSOpenPanel()
        panel.title = "打开蓝光原盘"
        panel.prompt = "打开"
        panel.message = "选择一个蓝光 ISO，会挂载后按播放列表播放"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        if let type = UTType(filenameExtension: "iso") {
            panel.allowedContentTypes = [type]
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }
        open(path: url.path)
    }

    /// 挂载放到后台：大 ISO 的 hdiutil 可能要一两秒，别卡住侧栏。
    static func open(path: String,
                     autoTitle: Int? = nil,
                     coreItemId: String? = nil,
                     hintTitle: String? = nil,
                     start: Double? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let session = try BluRayDisc.open(isoPath: path)
                DispatchQueue.main.async {
                    // 只有一条标题就别多一步：直接播；多标题才弹选择框。
                    let title = autoTitle.flatMap { wanted in
                        session.titles.first { $0.number == wanted }
                    } ?? (session.titles.count == 1 ? session.titles[0] : chooseTitle(session))

                    guard let title else {
                        session.detach()
                        return
                    }

                    PlayerLauncher.shared.playDisc(session, title: title,
                                                   coreItemId: coreItemId,
                                                   hintTitle: hintTitle,
                                                   start: start)
                }
            } catch {
                DispatchQueue.main.async {
                    let alert = NSAlert()
                    alert.messageText = "无法打开原盘"
                    alert.informativeText = error.localizedDescription
                    alert.alertStyle = .warning
                    alert.addButton(withTitle: "好")
                    alert.runModal()
                }
            }
        }
    }

    /// 原生弹窗 + 下拉框：正片排前面，和 Windows 的标题框一个顺序。
    private static func chooseTitle(_ session: BluRaySession) -> BluRayTitle? {
        let alert = NSAlert()
        alert.messageText = "打开蓝光原盘"
        alert.informativeText = "\(session.discName) · \(session.titles.count) 个标题"

        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: 390, height: 26),
                                  pullsDown: false)
        let ordered = session.titles.filter(session.isFeature)
            + session.titles.filter { !session.isFeature($0) }
        for title in ordered {
            let badge = session.isFeature(title) ? "正片" : "花絮"
            popup.addItem(withTitle: "\(badge)  标题 \(title.number) · \(title.durationLabel)")
        }

        alert.accessoryView = popup
        alert.addButton(withTitle: "播放")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = popup

        guard alert.runModal() == .alertFirstButtonReturn else { return nil }
        let index = popup.indexOfSelectedItem
        guard ordered.indices.contains(index) else { return nil }
        return ordered[index]
    }
}
