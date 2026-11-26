import SwiftUI
import AppKit

/// 原盘菜单：打开 ISO 先停在这里，选标题 / 章节再起播。
///
/// 原盘自带的 HDMV / BD-J 菜单跑不起来（mpv 没有 libbluray 的菜单引擎，
/// BD-J 还要 JVM），所以这里按 mpls 里的标题与 `PlayListMark` 自己画一版：
/// 左边标题（正片 / 花絮），右边章节，点章节就从那一章开始播。
@MainActor
final class DiscMenuController: NSWindowController, NSWindowDelegate {
    private let disc: BluRaySession
    private let playback: DiscPlayback
    private let onPlay: (BluRayTitle, Double) -> Void
    /// 已经交给播放器：关窗时不能卸载盘。
    private var playing = false

    init(disc: BluRaySession,
         playback: DiscPlayback,
         onPlay: @escaping (BluRayTitle, Double) -> Void) {
        self.disc = disc
        self.playback = playback
        self.onPlay = onPlay

        let visible = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let width = min(960, visible.width * 0.92)
        let height = min(620, visible.height * 0.88)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: width, height: height),
            styleMask: [.titled, .closable, .fullSizeContentView],
            backing: .buffered, defer: false)
        window.title = "\(playback.displayName) · 原盘"
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        // 自绘菜单没有系统标题栏可拖：整窗背景都能拖。
        window.isMovableByWindowBackground = true
        window.backgroundColor = NSColor(srgbRed: 0x14 / 255.0,
                                         green: 0x14 / 255.0,
                                         blue: 0x19 / 255.0, alpha: 1)
        window.standardWindowButton(.closeButton)?.isHidden = true
        window.standardWindowButton(.miniaturizeButton)?.isHidden = true
        window.standardWindowButton(.zoomButton)?.isHidden = true

        super.init(window: window)
        window.delegate = self

        var featureIds: Set<Int> = []
        for title in disc.titles where disc.isFeature(title) {
            featureIds.insert(title.id)
        }

        let root = DiscMenuView(
            discName: playback.displayName,
            titles: disc.titles,
            featureIds: featureIds,
            progress: { [disc, playback] title in
                let item = playback.itemId(for: title)
                let saved = LocalProgressStore.get(item)
                if saved > 0 { return saved }
                // 从媒体库点开的 ISO：续播点在核心那边（由播放器打开时带进来）。
                return title.id == Self.defaultTitle(in: disc)?.id
                    ? max(0, playback.suggestedStart ?? 0) : 0
            },
            onPlay: { [weak self] title, start in
                self?.start(title: title, at: start)
            },
            onClose: { [weak self] in self?.closeMenu() })

        window.contentView = NSHostingView(rootView: root)
        window.center()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func present() {
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// 起播：菜单收起，把标题和起点交给播放器。点标题 / 章节都是这一条路径。
    func start(title: BluRayTitle, at start: Double) {
        playing = true
        window?.orderOut(nil)
        onPlay(title, start)
    }

    /// 菜单默认选中的标题：最长的正片；没有正片就最长的标题。
    static func defaultTitle(in disc: BluRaySession) -> BluRayTitle? {
        let features = disc.titles.filter(disc.isFeature)
        let pool = features.isEmpty ? disc.titles : features
        return pool.sorted { first, second in
            if abs(first.duration - second.duration) > 0.5 {
                return first.duration > second.duration
            }
            return first.number < second.number
        }.first
    }

    /// 菜单窗口自己关闭（✕ / Esc / 关窗）：没起播就把盘卸掉。
    func closeMenu() {
        window?.orderOut(nil)
        close()
    }

    func windowWillClose(_ notification: Notification) {
        if !playing {
            disc.detach()
        }
    }

}

struct DiscMenuView: View {
    let discName: String
    let titles: [BluRayTitle]
    let featureIds: Set<Int>
    let progress: (BluRayTitle) -> Double
    let onPlay: (BluRayTitle, Double) -> Void
    let onClose: () -> Void

    @State private var selectedId: Int

    init(discName: String,
         titles: [BluRayTitle],
         featureIds: Set<Int>,
         progress: @escaping (BluRayTitle) -> Double,
         onPlay: @escaping (BluRayTitle, Double) -> Void,
         onClose: @escaping () -> Void) {
        self.discName = discName
        self.titles = titles
        self.featureIds = featureIds
        self.progress = progress
        self.onPlay = onPlay
        self.onClose = onClose

        let features = titles.filter { featureIds.contains($0.id) }
        let pool = features.isEmpty ? titles : features
        let first = pool.sorted {
            abs($0.duration - $1.duration) > 0.5
                ? $0.duration > $1.duration : $0.number < $1.number
        }.first
        _selectedId = State(initialValue: first?.id ?? titles.first?.id ?? 0)
    }

    private var features: [BluRayTitle] {
        titles.filter { featureIds.contains($0.id) }
            .sorted { $0.duration > $1.duration }
    }

    private var extras: [BluRayTitle] {
        titles.filter { !featureIds.contains($0.id) }
            .sorted { $0.number < $1.number }
    }

    private var selected: BluRayTitle? {
        titles.first { $0.id == selectedId }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            rule
            HStack(spacing: 0) {
                titleList
                    .frame(width: 320)
                ruleVertical
                chapterPane
            }
            rule
            footer
        }
        .background(Theme.bg)
        .preferredColorScheme(.dark)
        .onExitCommand(perform: onClose)
    }

    // MARK: - 顶栏

    private var header: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 9)
                .fill(Theme.surface)
                .frame(width: 38, height: 38)
                .overlay(
                    Image(systemName: "opticaldisc")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(Theme.accent)
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(discName)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Theme.text)
                    .lineLimit(1)
                Text(summary)
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.faint)
            }

            Spacer(minLength: 12)

            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 26, height: 26)
                    .background(Theme.surface, in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭（Esc）")
        }
        .padding(.horizontal, 18)
        .padding(.top, 30)
        .padding(.bottom, 14)
    }

    private var summary: String {
        var parts = ["\(titles.count) 个标题"]
        if !features.isEmpty {
            parts.append("\(features.count) 个正片")
        }
        return parts.joined(separator: " · ")
    }

    // MARK: - 标题列表

    private var titleList: some View {
        ScrollView(.vertical, showsIndicators: false) {
            LazyVStack(alignment: .leading, spacing: 6) {
                if !features.isEmpty {
                    groupLabel("正片")
                    ForEach(features) { title in row(title) }
                }
                if !extras.isEmpty {
                    groupLabel("花絮").padding(.top, features.isEmpty ? 0 : 10)
                    ForEach(extras) { title in row(title) }
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
        }
    }

    private func groupLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11.5, weight: .semibold))
            .foregroundStyle(Theme.faint)
            .padding(.horizontal, 4)
            .padding(.bottom, 2)
    }

    private func row(_ title: BluRayTitle) -> some View {
        let active = title.id == selectedId
        let saved = progress(title)

        return Button {
            selectedId = title.id
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text("标题 \(title.number)")
                            .font(.system(size: 13.5, weight: .semibold))
                            .foregroundStyle(Theme.text)
                        if featureIds.contains(title.id) {
                            Text("正片")
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(Theme.accent)
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(Theme.accent.opacity(0.14),
                                            in: RoundedRectangle(cornerRadius: 4))
                        }
                    }

                    Text(meta(title))
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.faint)
                }

                Spacer(minLength: 6)

                if saved > 0 {
                    Text("看到 \(timeLabel(saved))")
                        .font(.system(size: 11))
                        .foregroundStyle(Theme.muted)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(active ? Theme.surfaceHover : Theme.surface,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(
                RoundedRectangle(cornerRadius: 9)
                    .stroke(active ? Theme.accent.opacity(0.55) : Theme.line,
                            lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
    }

    private func meta(_ title: BluRayTitle) -> String {
        var parts = [timeLabel(title.duration)]
        if !title.chapters.isEmpty {
            parts.append("\(title.chapters.count) 章")
        }
        parts.append("\(title.clips.count) 段")
        return parts.joined(separator: " · ")
    }

    // MARK: - 章节

    private var chapterPane: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .bottom) {
                Text("章节")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Theme.text)
                if let selected, !selected.chapters.isEmpty {
                    Text("\(selected.chapters.count)")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                }
                Spacer()
                if let selected {
                    Text("标题 \(selected.number) · \(timeLabel(selected.duration))")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                }
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            if let selected, !selected.chapters.isEmpty {
                ScrollView(.vertical, showsIndicators: false) {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 132), spacing: 8)],
                              alignment: .leading, spacing: 8) {
                        ForEach(selected.chapters) { chapter in
                            chapterButton(chapter, title: selected)
                        }
                    }
                    .padding(.horizontal, 18)
                    .padding(.bottom, 14)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: "list.bullet.rectangle")
                        .font(.system(size: 22))
                        .foregroundStyle(Theme.faint)
                    Text("这张盘没有章节标记")
                        .font(.system(size: 13))
                        .foregroundStyle(Theme.muted)
                    Text("点下面的「从头播放」整段播放。")
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func chapterButton(_ chapter: BluRayChapter, title: BluRayTitle) -> some View {
        Button {
            onPlay(title, chapter.time)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text("第 \(chapter.id) 章")
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(Theme.text)
                Text(chapter.timeLabel)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
            .overlay(
                RoundedRectangle(cornerRadius: 8).stroke(Theme.line, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(.plain)
        .help("从 \(chapter.timeLabel) 开始播放")
    }

    // MARK: - 底部

    private var footer: some View {
        HStack(spacing: 10) {
            if let selected {
                Button("从头播放") { onPlay(selected, 0) }
                    .buttonStyle(PrimaryButtonStyle())

                let saved = progress(selected)
                if saved > 0 {
                    Button("继续 \(timeLabel(saved))") { onPlay(selected, saved) }
                        .buttonStyle(SecondaryButtonStyle())
                }
            }

            Spacer(minLength: 8)

            Text("点章节可以直接从那一章开始")
                .font(.system(size: 11.5))
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
    }

    // MARK: - 小工具

    private var rule: some View {
        Rectangle().fill(Theme.line).frame(height: 1)
    }

    private var ruleVertical: some View {
        Rectangle().fill(Theme.line).frame(width: 1)
    }

    private func timeLabel(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, total % 60)
            : String(format: "%d:%02d", minutes, total % 60)
    }
}

/// 菜单窗口的持有者：同一时间只开一张盘，再打开就替换。
@MainActor
enum DiscMenuLauncher {
    private static var current: DiscMenuController?

    static func present(disc: DiscPlayback) {
        current?.closeMenu()

        let controller = DiscMenuController(disc: disc.disc, playback: disc) { title, start in
            PlayerLauncher.shared.playDisc(disc, title: title, start: start)
        }
        current = controller
        controller.present()

        let env = ProcessInfo.processInfo.environment

        // 自检：`DVPLAYER_DISC_MENU_SHOT=<png>` 截一张菜单再退出。
        if let shot = env["DVPLAYER_DISC_MENU_SHOT"], !shot.isEmpty {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_800_000_000)
                if let window = controller.window {
                    AppDelegate.capture(to: shot, window: window)
                }
                NSApp.terminate(nil)
            }
        }

        // 自检：`DVPLAYER_DISC_MENU_PLAY=<秒>` 走菜单的起播路径（等于点章节），
        // 验证「菜单 → 播放器」这一段，而不是绕过菜单直接播。
        if let raw = env["DVPLAYER_DISC_MENU_PLAY"], let start = Double(raw),
           let title = DiscMenuController.defaultTitle(in: disc.disc) {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                NSLog("[Disc] menu play title=\(title.number) at=\(start)")
                controller.start(title: title, at: max(0, start))
            }
        }
    }
}
