import AppKit
import UniformTypeIdentifiers

/// 打开原盘的入口：选 ISO → 挂载 → 蓝光读 mpls（默认进盘内菜单），
/// DVD 按主 VTS 的 VOB 顺序连播（见 `BluRayDisc.DvdSession`）。
@MainActor
enum DiscUI {
    static func chooseAndPlay() {
        let panel = NSOpenPanel()
        panel.title = "打开蓝光 / DVD 镜像"
        panel.prompt = "打开"
        panel.message = "选择一个蓝光 / DVD ISO，会挂载后播放"
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
    /// - Parameter useMenu: 强制进盘内菜单（`bd://` + `--disc-menu`），给
    ///   `DVPLAYER_DISC_MENU_KEYS` 自检用。默认按盘的类型决定：HDMV 进菜单，
    ///   BD-J 直连正片（BD-J 菜单要 Java VM + libbluray 的 BD-J jar，随包的
    ///   libbluray 没有，mpv 只能 "Playing without menus"）。
    static func open(path: String,
                     autoTitle: Int? = nil,
                     coreItemId: String? = nil,
                     hintTitle: String? = nil,
                     start: Double? = nil,
                     useMenu: Bool = false) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                switch try BluRayDisc.open(isoPath: path) {
                    case .bluray(let session):
                        DispatchQueue.main.async {
                            NSLog("[Disc] titles=\(session.titles.count) "
                                  + session.titles.map { title in
                                      "\(session.isFeature(title) ? "正片" : "花絮")"
                                      + " \(title.number):\(Int(title.duration))s"
                                      + "/\(title.chapters.count)章"
                                  }.joined(separator: " "))

                            let disc = DiscPlayback(disc: session,
                                                    hintTitle: hintTitle,
                                                    coreItemId: coreItemId,
                                                    suggestedStart: start)

                            // 自检 / `DVPLAYER_DISC_TITLE`：指定了标题就直接播，
                            // 回归脚本不用点菜单。
                            if let autoTitle,
                               let title = session.titles.first(where: { $0.number == autoTitle }) {
                                NSLog("[Disc] direct title=\(title.number) mpls=\(title.id) " +
                                      "dur=\(Int(title.duration)) of \(session.titles.count)")
                                PlayerLauncher.shared.playDisc(disc, title: title, start: start)
                                return
                            }

                            // HDMV 盘默认进盘里自带的菜单（libbluray HDMV 导航 +
                            // mpv 的 IG overlay 渲染，实测按钮能画出来）。点按钮后
                            // mpv 自己切标题，壳不用重新生成 EDL。
                            // BD-J 盘的菜单要 Java VM + libbluray 的 BD-J jar，
                            // 随包的 libbluray 没有，mpv 只能 "Playing without
                            // menus"——进菜单只剩菜单背景视频，控制条又被菜单
                            // 状态收掉。所以 BD-J 盘直接播正片。
                            if useMenu || !session.hasBDJ {
                                NSLog("[Disc] menu titles=\(session.titles.count) "
                                      + "hdmv=\(!session.hasBDJ) bdj=\(session.hasBDJ) "
                                      + session.titles.map { "\($0.id):\($0.chapters.count)" }
                                        .joined(separator: ","))
                                PlayerLauncher.shared.playDiscMenu(disc)
                                return
                            }

                            // BD-J：直接播最长的正片。其它标题在右侧「标题」
                            // 面板切，和 Windows 菜单里选完标题后是同一套交互。
                            guard let title = session.titles
                                .filter(session.isFeature)
                                .max(by: { $0.duration < $1.duration })
                                ?? session.titles.max(by: { $0.duration < $1.duration })
                            else {
                                AppState.shared.showToast("这张盘里没有可播放的标题")
                                session.detach()
                                return
                            }

                            // 核心给的续播点可能来自这张盘的上一版（菜单条目），
                            // 超出这条正片时长就别用，免得一开就播到结尾。
                            let resume = start.flatMap { value in
                                value > 0 && value < title.duration - 5 ? value : nil
                            }
                            NSLog("[Disc] direct title=\(title.number) mpls=\(title.id) "
                                  + "dur=\(Int(title.duration)) of \(session.titles.count) "
                                  + "resume=\(Int(resume ?? 0)) noMenu=true")
                            PlayerLauncher.shared.playDisc(disc, title: title, start: resume)
                        }

                    case .dvd(let dvd):
                        // DVD 没有菜单导航（mac 的 libmpv 是 LGPL 构建），按主 VTS
                        // 的 VOB 顺序连播，和普通视频一样用控制条 / 进度。
                        DispatchQueue.main.async {
                            NSLog("[Disc] dvd vob=\(dvd.clips.count) "
                                  + "dur=\(Int(dvd.duration))s")
                            PlayerLauncher.shared.playDvd(dvd,
                                                          coreItemId: coreItemId,
                                                          hintTitle: hintTitle,
                                                          start: start)
                        }
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
}
