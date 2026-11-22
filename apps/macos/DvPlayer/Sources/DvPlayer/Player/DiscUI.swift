import AppKit
import UniformTypeIdentifiers

/// 打开蓝光原盘的入口：选 ISO → 挂载读标题 → 直接播默认标题（最长的正片）。
/// 其它标题在播放器右侧的「标题」面板里切，和选集是同一套交互（与 Windows 一致）。
@MainActor
enum DiscUI {
    static func chooseAndPlay() {
        let panel = NSOpenPanel()
        panel.title = "打开蓝光原盘"
        panel.prompt = "打开"
        panel.message = "选择一个蓝光 ISO，会挂载后直接播放正片"
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
                    NSLog("[Disc] titles=\(session.titles.count) "
                          + session.titles.map { title in
                              "\(session.isFeature(title) ? "正片" : "花絮")"
                              + " \(title.number):\(Int(title.duration))s"
                          }.joined(separator: " "))

                    // 直接播默认标题，不再弹选择框；
                    // `DVPLAYER_DISC_TITLE=N` 只是自检时指定第 N 个标题。
                    let title = autoTitle.flatMap { wanted in
                        session.titles.first { $0.number == wanted }
                    } ?? defaultTitle(session)

                    guard let title else {
                        session.detach()
                        return
                    }

                    let disc = DiscPlayback(disc: session,
                                            hintTitle: hintTitle,
                                            coreItemId: coreItemId)
                    NSLog("[Disc] default title=\(title.number) mpls=\(title.id) " +
                          "dur=\(Int(title.duration)) of \(session.titles.count)")
                    PlayerLauncher.shared.playDisc(disc, title: title, start: start)
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

    /// 没指定标题时播哪个：最长的正片；没有正片就最长的标题。
    static func defaultTitle(_ session: BluRaySession) -> BluRayTitle? {
        let features = session.titles.filter(session.isFeature)
        let pool = features.isEmpty ? session.titles : features
        return pool.sorted { first, second in
            if abs(first.duration - second.duration) > 0.5 {
                return first.duration > second.duration
            }
            return first.number < second.number
        }.first
    }
}
