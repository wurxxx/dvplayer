import AppKit
import SwiftUI
import DvCore

/// 播放页的浮层（视频在 mpv 自己的窗口里，这个视图透明地盖在它上面）。
///
/// 布局照 Windows 的 `PlayWindow.xaml`：顶部片名 + 右上角窗口按钮、
/// 底部规格标签和控制条、右侧截图 / 选集、右侧选集面板、媒体信息面板。
struct PlayerView: View {
    @ObservedObject var session: PlayerSession
    let actions: PlayerActions
    /// 浮层宽度：竖屏短剧的窗口只有 400 来像素，底部控制条要换两行。
    @State private var viewWidth: CGFloat = 0

    var body: some View {
        ZStack {
            // 点画面：单击暂停、双击全屏；鼠标一动把控制条叫回来。
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { session.toggleFullscreen() }
                .onTapGesture { session.togglePause() }
                .onContinuousHover { phase in
                    if case .active = phase {
                        session.showChrome()
                    }
                }

            // 无标题栏，顶栏那块按住拖窗口。
            VStack(spacing: 0) {
                PlayerDragArea(action: actions.dragWindow,
                               onDoubleClick: actions.toggleFullscreen)
                    .frame(height: 30)
                Spacer(minLength: 0)
            }

            if session.loading {
                loadingPanel
            }

            if let error = session.error {
                errorPanel(error)
            }

            if session.isFullscreen == false {
                windowDots
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }

            if session.chromeVisible || session.panel != .none {
                topBar
                    .frame(maxHeight: .infinity, alignment: .top)
                rightActions
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 18)
            }

            if session.chromeVisible {
                bottomBar
                    .frame(maxHeight: .infinity, alignment: .bottom)
            }

            if session.panel == .episodes {
                episodesPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 74)
                    .padding(.vertical, 40)
            }

            if session.panel == .info {
                infoPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 74)
                    .padding(.vertical, 40)
            }

            if session.panel == .subtitles {
                subtitlesPanel
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .trailing)
                    .padding(.trailing, 74)
                    .padding(.vertical, 40)
            }

            // 片尾区间到了浮出来，不自动跳，给用户自己决定。
            if session.showSkipOutro {
                skipOutroButton
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(.trailing, 24)
                    .padding(.bottom, 118)
            }

            if let toast = session.toast {
                toastView(toast)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .padding(.bottom, 132)
            }
        }
        .background(
            GeometryReader { proxy in
                Color.clear
                    .onAppear { viewWidth = proxy.size.width }
                    .onChange(of: proxy.size.width) { width in viewWidth = width }
            }
        )
        .onAppear { session.showChrome() }
    }

    // MARK: - 顶部

    private var topBar: some View {
        ZStack(alignment: .top) {
            LinearGradient(colors: [.black.opacity(0.6), .clear],
                           startPoint: .top, endPoint: .bottom)
                .frame(height: 100)
                .allowsHitTesting(false)

            Text(session.title)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.95))
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: 560)
                .padding(.top, 14)
                .allowsHitTesting(false)
        }
        .opacity(session.chromeVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: session.chromeVisible)
    }

    private var windowDots: some View {
        HStack(spacing: 8) {
            PlayerDot(color: Color(hex: 0xFF5F57), glyph: "xmark") { actions.close() }
            PlayerDot(color: Color(hex: 0xFEBC2E), glyph: "minus") { actions.minimize() }
            PlayerDot(color: Color(hex: 0x28C840), glyph: "plus") { actions.zoom() }
        }
        .padding(.leading, 18)
        .padding(.top, 14)
    }

    private var rightActions: some View {
        VStack(spacing: 8) {
            PlayerCircleButton(icon: "camera", tip: "截图") {
                session.screenshot()
            }
            if session.playlist.count > 1 {
                PlayerCircleButton(icon: "list.bullet.rectangle", tip: "选集",
                                   active: session.panel == .episodes) {
                    session.togglePanel(.episodes)
                }
            }
        }
        .opacity(session.chromeVisible || session.panel != .none ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: session.chromeVisible)
    }

    // MARK: - 底部

    private var bottomBar: some View {
        VStack(alignment: .leading, spacing: 10) {
            if !session.chips.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(session.chips, id: \.self) { chip in
                            Text(chip)
                                .font(.system(size: 11.5))
                                .foregroundStyle(Color.white.opacity(0.9))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(Color.black.opacity(0.4),
                                            in: RoundedRectangle(cornerRadius: 4))
                                .allowsHitTesting(false)
                        }
                    }
                }
            }

            if isCompact {
                // 竖屏窗口：只留传输 + 进度 + 「更多」，其余工具在更多菜单里。
                HStack(spacing: 6) {
                    playRow
                    moreMenu
                }
            } else {
                HStack(spacing: 6) {
                    playRow
                    toolsRow
                        .layoutPriority(1)
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 18)
        .padding(.top, 60)
        .background(alignment: .bottom) {
            LinearGradient(colors: [.clear, .black.opacity(0.5), .black.opacity(0.9)],
                           startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        }
        .opacity(session.chromeVisible ? 1 : 0)
        .animation(.easeOut(duration: 0.15), value: session.chromeVisible)
    }

    private var isCompact: Bool { viewWidth > 0 && viewWidth < 640 }

    private var playRow: some View {
        HStack(spacing: 6) {
            PlayerBarButton(icon: "backward.end.fill", size: 13) {
                session.previousEpisode()
            }
            .help("上一集（PageUp）")

            PlayerBarButton(icon: session.paused ? "play.fill" : "pause.fill", size: 16) {
                session.togglePause()
            }
            .help("播放 / 暂停（空格）")

            PlayerBarButton(icon: "forward.end.fill", size: 13) {
                session.nextEpisode()
            }
            .help("下一集（PageDown）")

            Text(timeText(session.seekPosition))
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(width: 56, alignment: .leading)
                .padding(.leading, 4)

            seekBar

            Text(timeText(session.duration))
                .font(.system(size: 12.5))
                .monospacedDigit()
                .foregroundStyle(Color.white.opacity(0.7))
                .frame(width: 66, alignment: .leading)
        }
    }

    /// 三层进度条：已观看（主色）/ 已缓冲（亮白）/ 未观看（暗白）。
    /// 用自绘而不是 Slider，才能把缓存那一段单独染色；拖动和点击都还行。
    private var seekBar: some View {
        GeometryReader { proxy in
            let width = max(1, proxy.size.width)
            let total = max(1, session.duration)
            let played = min(max(session.isScrubbing ? session.seekPosition : session.position,
                                 0), total)
            let buffered = min(max(session.bufferedPosition, played), total)
            let playedWidth = width * played / total
            let bufferedWidth = width * buffered / total

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(Color.white.opacity(0.22))
                    .frame(height: 4)

                Capsule()
                    .fill(Color.white.opacity(0.55))
                    .frame(width: bufferedWidth, height: 4)

                Capsule()
                    .fill(Theme.accent)
                    .frame(width: playedWidth, height: 4)

                Circle()
                    .fill(Color.white)
                    .frame(width: session.isScrubbing ? 11 : 9,
                           height: session.isScrubbing ? 11 : 9)
                    .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                    .position(x: min(max(playedWidth, 5), width - 5), y: 9)
            }
            .frame(height: 18)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        if !session.isScrubbing {
                            session.setScrubbing(true)
                        }
                        let ratio = Double(value.location.x / width)
                        session.seekPosition = min(max(ratio, 0), 1) * total
                    }
                    .onEnded { _ in
                        session.setScrubbing(false)
                    }
            )
        }
        .frame(height: 18)
    }

    private var toolsRow: some View {
        HStack(spacing: 6) {
            PlayerBarButton(icon: session.muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                            size: 13) {
                session.toggleMute()
            }
            .help("静音（M）")

            Slider(value: Binding(get: { session.volume },
                                  set: { session.setVolume($0) }),
                   in: 0...100)
                .frame(width: 84)
                .tint(.white)
                .controlSize(.small)

            audioMenu
            subtitleMenu
            speedMenu

            PlayerBarButton(icon: session.isFullscreen
                                ? "arrow.down.right.and.arrow.up.left"
                                : "arrow.up.left.and.arrow.down.right",
                            size: 13) {
                session.toggleFullscreen()
            }
            .help("全屏（F / 双击画面）")

            moreMenu
        }
    }

    // MARK: - 菜单

    private var skipOutroButton: some View {
        Button {
            session.skipOutro()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 11))
                Text("跳过片尾")
                    .font(.system(size: 12.5, weight: .medium))
            }
            .foregroundStyle(Color.white.opacity(0.95))
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(Color.black.opacity(0.62),
                        in: RoundedRectangle(cornerRadius: 8))
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.white.opacity(0.18), lineWidth: 1)
            }
        }
        .buttonStyle(.plain)
        .help("直接接下一集")
    }

    @ViewBuilder
    private var audioMenuItems: some View {
        if session.audioTracks.isEmpty {
            Text("没有音轨信息")
        }
        ForEach(session.audioTracks) { track in
            Button {
                session.selectAudio(track.id)
            } label: {
                if session.selectedAudioId == track.id {
                    Label(trackLabel(track), systemImage: "checkmark")
                } else {
                    Text(trackLabel(track))
                }
            }
        }
    }

    private var audioMenu: some View {
        Menu {
            audioMenuItems
        } label: {
            PlayerMenuIcon(icon: "waveform")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("音轨")
    }

    @ViewBuilder
    private var subtitleMenuItems: some View {
        Button {
            session.selectSubtitle(0)
        } label: {
            if session.selectedSubtitleId == 0 {
                Label("关闭字幕", systemImage: "checkmark")
            } else {
                Text("关闭字幕")
            }
        }

        if session.subtitleTracks.isEmpty {
            Divider()
            Text("没有字幕轨")
        } else {
            Divider()
            ForEach(session.subtitleTracks) { track in
                Button {
                    session.selectSubtitle(track.id)
                } label: {
                    if session.selectedSubtitleId == track.id {
                        Label(trackLabel(track), systemImage: "checkmark")
                    } else {
                        Text(trackLabel(track))
                    }
                }
            }
        }
    }

    private var subtitleMenu: some View {
        Menu {
            subtitleMenuItems
        } label: {
            PlayerMenuIcon(icon: "captions.bubble")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("字幕")
    }

    @ViewBuilder
    private var speedMenuItems: some View {
        ForEach([0.5, 0.75, 1.0, 1.25, 1.5, 2.0], id: \.self) { speed in
            Button {
                session.setSpeed(speed)
            } label: {
                if abs(session.speed - speed) < 0.01 {
                    Label(speedLabel(speed), systemImage: "checkmark")
                } else {
                    Text(speedLabel(speed))
                }
            }
        }
    }

    private var speedMenu: some View {
        Menu {
            speedMenuItems
        } label: {
            Text(speedLabel(session.speed))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(width: 34, height: 26)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("播放速度")
    }

    private var moreMenu: some View {
        Menu {
            Button("上一集") { session.previousEpisode() }
            Button("下一集") { session.nextEpisode() }
            Divider()

            Menu("画面比例（\(session.aspect.label)）") {
                ForEach(PlayerAspect.allCases) { mode in
                    Button {
                        session.setAspect(mode)
                    } label: {
                        if session.aspect == mode {
                            Label(mode.label, systemImage: "checkmark")
                        } else {
                            Text(mode.label)
                        }
                    }
                }
            }

            Menu(session.sleepLabel.map { "定时关闭（\($0)）" } ?? "定时关闭") {
                Button("不定时") { session.cancelSleep() }
                Divider()
                Button("15 分钟后") { session.setSleep(minutes: 15) }
                Button("30 分钟后") { session.setSleep(minutes: 30) }
                Button("45 分钟后") { session.setSleep(minutes: 45) }
                Button("60 分钟后") { session.setSleep(minutes: 60) }
                Button("90 分钟后") { session.setSleep(minutes: 90) }
                Divider()
                Button("本集结束后") { session.setSleepEndOfEpisode() }
            }

            Divider()

            Button(session.danmakuEnabled ? "弹幕：开" : "弹幕：关") {
                session.setDanmaku(enabled: !session.danmakuEnabled)
            }

            Divider()

            if let intro = session.markers.introEnd {
                Button("清除片头标记（\(timeText(intro))）") { session.clearIntro() }
            } else {
                Button("把当前位置设为片头结束") { session.markIntroEnd() }
            }
            if let outro = session.markers.outroStart {
                Button("清除片尾标记（\(timeText(outro))）") { session.clearOutro() }
            } else {
                Button("把当前位置设为片尾开始") { session.markOutroStart() }
            }
            if !session.markers.isEmpty {
                Button("清除本剧全部标记") { session.clearMarkers() }
            }

            Divider()
            Button("搜索字幕…") { session.openSubtitleSearch() }

            if isCompact {
                // 窄窗口控制条上放不下的工具，收到这里。
                Divider()
                Button(session.muted ? "取消静音" : "静音") { session.toggleMute() }
                Button("音量 +10") { session.setVolume(session.volume + 10) }
                Button("音量 −10") { session.setVolume(session.volume - 10) }
                Menu("音轨") { audioMenuItems }
                Menu("字幕") { subtitleMenuItems }
                Menu("倍速") { speedMenuItems }
            }

            Button("媒体信息") { session.togglePanel(.info) }
            Button("截图") { session.screenshot() }
            Button(session.isFullscreen ? "退出全屏" : "全屏") {
                session.toggleFullscreen()
            }
            Divider()
            Button("关闭") { actions.close() }
        } label: {
            PlayerMenuIcon(icon: "ellipsis")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("更多")
    }

    private func trackLabel(_ track: PlayerTrack) -> String {
        track.detail.isEmpty ? track.name : "\(track.name)（\(track.detail)）"
    }

    private func speedLabel(_ speed: Double) -> String {
        "\(speed == speed.rounded() ? String(Int(speed)) : String(format: "%.2g", speed))×"
    }

    private func timeText(_ seconds: Double) -> String {
        let total = Int(max(0, seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%02d:%02d", total / 60, total % 60)
    }

    // MARK: - 选集 / 媒体信息

    private var subtitlesPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("字幕搜索")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                if session.subtitleSearching {
                    ProgressView()
                        .controlSize(.small)
                } else if !session.subtitleResults.isEmpty {
                    Text("\(session.subtitleResults.count) 条")
                        .font(.system(size: 11.5))
                        .foregroundStyle(Theme.faint)
                }
                Button {
                    session.panel = .none
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain)
                .padding(.leading, 8)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if let error = session.subtitleError {
                Text(error)
                    .font(.system(size: 12.5))
                    .foregroundStyle(Color(hex: 0xFF6B6B))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 24)
            } else if session.subtitleSearching {
                Text("正在搜索…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.faint)
                    .padding(.vertical, 30)
            } else if session.subtitleResults.isEmpty {
                Text("没有结果")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.faint)
                    .padding(.vertical, 30)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(session.subtitleResults) { result in
                            Button {
                                session.applySubtitle(result)
                            } label: {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(result.languageLabel)
                                        .font(.system(size: 13.5, weight: .semibold))
                                        .foregroundStyle(Theme.text)
                                    Text(result.detail)
                                        .font(.system(size: 11.5))
                                        .foregroundStyle(Theme.faint)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 9)
                                .background(Color.white.opacity(0.05),
                                            in: RoundedRectangle(cornerRadius: 7))
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.bottom, 10)
                }
            }
        }
        .frame(width: 380)
        .frame(maxHeight: 580)
        .background(Color(hex: 0x141419).opacity(0.96),
                    in: RoundedRectangle(cornerRadius: Theme.radiusCard))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusCard)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        }
    }

    private var episodesPanel: some View {
        VStack(spacing: 0) {
            HStack {
                Text("选集")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Text("\(session.playlist.count) 集")
                    .font(.system(size: 11.5))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 8)

            if session.playlist.isEmpty {
                Text("正在读取选集…")
                    .font(.system(size: 12.5))
                    .foregroundStyle(Theme.faint)
                    .padding(.vertical, 30)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 6) {
                            ForEach(session.playlist) { episode in
                                episodeRow(episode)
                                    .id(episode.id)
                            }
                        }
                        .padding(.horizontal, 8)
                        .padding(.bottom, 10)
                    }
                    .onAppear {
                        // 打开面板时直接落到正在播的那一集。
                        proxy.scrollTo(session.itemId, anchor: .center)
                    }
                    .onChange(of: session.itemId) { id in
                        withAnimation(.easeOut(duration: 0.2)) {
                            proxy.scrollTo(id, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(width: 380)
        .frame(maxHeight: 580)
        .background(Color(hex: 0x141419).opacity(0.96),
                    in: RoundedRectangle(cornerRadius: Theme.radiusCard))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusCard)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        }
    }

    private func episodeRow(_ episode: PlayerEpisode) -> some View {
        let active = episode.id == session.itemId
        return Button {
            session.playEpisode(episode)
        } label: {
            HStack(spacing: 12) {
                PosterImage(path: episode.posterPath, title: episode.title)
                    .frame(width: 132, height: 74)
                    .clipShape(RoundedRectangle(cornerRadius: 7))

                VStack(alignment: .leading, spacing: 5) {
                    Text(episode.badge)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(Theme.text)
                        .lineLimit(1)
                    if !episode.meta.isEmpty {
                        Text(episode.meta)
                            .font(.system(size: 12))
                            .foregroundStyle(Theme.faint)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                Spacer(minLength: 0)
            }
            .padding(6)
            .background(active ? Color.white.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(Theme.accent, lineWidth: 2)
                        .padding(-1)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
    }

    private var infoPanel: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("媒体信息")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Theme.text)
                Spacer()
                Button {
                    session.panel = .none
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.muted)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 18)
            .padding(.top, 14)
            .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if let source = session.source {
                        infoSection("视频", lines: videoLines(source))
                    }
                    if let info = session.mediaInfo, !info.audios.isEmpty {
                        infoSection("音频 · \(info.audios.count) 条",
                                    lines: audioLines(info))
                    }
                    if let info = session.mediaInfo, !info.subtitles.isEmpty {
                        infoSection("字幕 · \(info.subtitles.count) 条",
                                    lines: subtitleLines(info))
                    }
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 16)
            }
        }
        .frame(width: 380)
        .frame(maxHeight: 520)
        .background(Color(hex: 0x141419).opacity(0.96),
                    in: RoundedRectangle(cornerRadius: Theme.radiusCard))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusCard)
                .stroke(Color.white.opacity(0.15), lineWidth: 1)
        }
    }

    private func infoSection(_ title: String, lines: [(String, String)]) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(Theme.muted)
            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                HStack(alignment: .top, spacing: 12) {
                    Text(line.0)
                        .font(.system(size: 12))
                        .foregroundStyle(Theme.faint)
                        .frame(width: 72, alignment: .leading)
                    Text(line.1)
                        .font(.system(size: 12))
                        .foregroundStyle(Color.white.opacity(0.82))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func videoLines(_ source: PlaySource) -> [(String, String)] {
        let video = session.mediaInfo?.video
        var lines: [(String, String)] = []
        lines.append(("编码", video?.codec ?? source.videoCodec ?? "--"))
        let size: String? = {
            guard let width = video?.width, let height = video?.height,
                  width > 0, height > 0 else { return nil }
            return "\(width)x\(height)"
        }()
        lines.append(("分辨率", video?.resolutionLabel ?? source.resolution ?? size ?? "--"))
        lines.append(("动态范围", video?.colorRange ?? source.colorRange ?? "SDR"))
        if source.dolbyVision || video?.dolbyVision == true {
            lines.append(("杜比视界", "是"))
        }
        if let fps = video?.frameRate, fps > 0 {
            lines.append(("帧率", "\(Int(fps.rounded())) FPS"))
        }
        if let bitRate = video?.bitRate, bitRate > 0 {
            lines.append(("码率", String(format: "%.1f Mbps", Double(bitRate) / 1_000_000)))
        }
        if let audio = video?.title, !audio.isEmpty {
            lines.append(("标题", audio))
        }
        return lines
    }

    private func audioLines(_ info: MediaInfo) -> [(String, String)] {
        info.audios.enumerated().map { index, audio in
            var parts: [String] = []
            if let language = audio.language, !language.isEmpty { parts.append(language) }
            if let codec = audio.codec, !codec.isEmpty { parts.append(codec) }
            if let channels = audio.channels, channels > 0 { parts.append("\(channels) ch") }
            if audio.isDefault == true { parts.append("默认") }
            let label = TrackPrefs.audioName(language: audio.language,
                                             title: audio.title,
                                             codec: audio.codec)
            let selected = session.selectedAudioId == session.audioTracks[safe: index]?.id
            return (label, (selected ? "✓ " : "") + parts.joined(separator: " · "))
        }
    }

    private func subtitleLines(_ info: MediaInfo) -> [(String, String)] {
        info.subtitles.enumerated().map { index, subtitle in
            var parts: [String] = []
            if let language = subtitle.language, !language.isEmpty { parts.append(language) }
            if let codec = subtitle.codec, !codec.isEmpty { parts.append(codec) }
            if subtitle.isBitmap == true { parts.append("图形字幕") }
            let label = TrackPrefs.subtitleName(language: subtitle.language,
                                                title: subtitle.title,
                                                codec: subtitle.codec)
            let selected = session.selectedSubtitleId == session.subtitleTracks[safe: index]?.id
            return (label, (selected ? "✓ " : "") + parts.joined(separator: " · "))
        }
    }

    // MARK: - 提示

    private var loadingPanel: some View {
        VStack(spacing: 10) {
            Text(session.title)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.white.opacity(0.9))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 720)
            Text("正在打开…")
                .font(.system(size: 13.5))
                .foregroundStyle(Color.white.opacity(0.6))
        }
        .padding(28)
    }

    private func errorPanel(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("播放失败")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Theme.danger)
            Text(message)
                .font(.system(size: 13))
                .foregroundStyle(Color.white.opacity(0.75))
                .fixedSize(horizontal: false, vertical: true)
            Button("关闭") { actions.close() }
                .buttonStyle(.bordered)
                .padding(.top, 6)
        }
        .padding(24)
        .frame(maxWidth: 560, alignment: .leading)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14))
    }

    private func toastView(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 13.5))
            .foregroundStyle(Color.white.opacity(0.95))
            .padding(.horizontal, 14)
            .padding(.vertical, 7)
            .background(Color.black.opacity(0.7), in: Capsule())
    }
}

// MARK: - 小控件

private struct PlayerDot: View {
    let color: Color
    let glyph: String
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 12, height: 12)
                .overlay {
                    if hovering {
                        Image(systemName: glyph)
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(Color.black.opacity(0.6))
                    }
                }
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PlayerCircleButton: View {
    let icon: String
    var tip: String = ""
    var active: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundStyle(Color.white.opacity(0.9))
                .frame(width: 36, height: 36)
                .background(hovering || active ? Color.white.opacity(0.16) : Color.black.opacity(0.3),
                            in: Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(tip)
    }
}

private struct PlayerBarButton: View {
    let icon: String
    var size: CGFloat = 14
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: size))
                .foregroundStyle(Color.white.opacity(0.92))
                .frame(width: 30, height: 26)
                .background(hovering ? Color.white.opacity(0.14) : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct PlayerMenuIcon: View {
    let icon: String
    @State private var hovering = false

    var body: some View {
        Image(systemName: icon)
            .font(.system(size: 14))
            .foregroundStyle(Color.white.opacity(0.9))
            .frame(width: 30, height: 26)
            .background(hovering ? Color.white.opacity(0.14) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7))
            .onHover { hovering = $0 }
    }
}

/// 无标题栏的拖窗区：按住移动窗口，双击全屏。
private struct PlayerDragArea: NSViewRepresentable {
    let action: (NSEvent) -> Void
    let onDoubleClick: () -> Void

    func makeNSView(context: Context) -> NSView {
        let view = DragView()
        view.action = action
        view.onDoubleClick = onDoubleClick
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard let view = nsView as? DragView else { return }
        view.action = action
        view.onDoubleClick = onDoubleClick
    }

    private final class DragView: NSView {
        var action: ((NSEvent) -> Void)?
        var onDoubleClick: (() -> Void)?

        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 {
                onDoubleClick?()
                return
            }
            action?(event)
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
