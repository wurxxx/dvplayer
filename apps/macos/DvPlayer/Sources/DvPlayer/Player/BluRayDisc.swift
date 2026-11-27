import Foundation

/// 蓝光 mpls 里的一段：从 `BDMV/STREAM/<stream>` 的第 `start` 秒起，播 `duration` 秒。
struct BluRayClip: Hashable {
    let stream: String
    let start: Double
    let duration: Double
}

/// 原盘里的一个章节：`time` 是从这个标题开头算的秒数（相对整条 playlist，
/// 不是单个 m2ts 片段），点章节就用它当起播点。
struct BluRayChapter: Identifiable, Hashable {
    /// 从 1 起，给用户看。
    let id: Int
    let time: Double

    var timeLabel: String {
        let total = max(0, Int(time.rounded()))
        let hours = total / 3600
        let minutes = total % 3600 / 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, total % 60)
            : String(format: "%d:%02d", minutes, total % 60)
    }
}

/// 原盘里的一个标题（一个 mpls）。
struct BluRayTitle: Identifiable, Hashable {
    /// mpls 编号（00001 → 1），也当播放时识别用。
    let id: Int
    /// 列表里的第几个标题（从 1 起），给用户看。
    let number: Int
    let duration: Double
    let clips: [BluRayClip]
    /// mpls 的 PlayListMark（mark_type = 1），按时间排序；空表示这张盘没标章节。
    var chapters: [BluRayChapter] = []

    var durationLabel: String {
        let total = Int(duration.rounded())
        let hours = total / 3600
        let minutes = total % 3600 / 60
        return hours > 0
            ? String(format: "%d:%02d:%02d", hours, minutes, total % 60)
            : String(format: "%d:%02d", minutes, total % 60)
    }
}

/// 一张 DVD-Video 镜像里的一个 VOB（主 VTS 的非菜单部分）。
struct DvdClip {
    let url: URL
    let duration: Double
}

/// 一张已经挂载的 DVD-Video 镜像（`VIDEO_TS`）。
///
/// mac 随包的 libmpv 是 **LGPL** 构建（`-Dgpl=false`），而 mpv 的 DVD 导航
/// 要链 GPL 的 libdvdread / libdvdnav（`-Ddvdnav` 在非 GPL 构建里直接报错），
/// 所以这里不走 `dvdnav://`：把主 VTS 的 VOB 按顺序拼成一份 EDL 播。
///
/// 代价是没有 DVD 菜单 / 标题 / 章节：一碟连播，换集靠进度条。
/// 换来的是不用重编成 GPL 的 libmpv。
final class DvdSession {
    let isoPath: String
    let mountPoint: URL
    let discName: String
    let clips: [DvdClip]
    let duration: Double

    private var edlURL: URL?
    private var detached = false

    init(isoPath: String, mountPoint: URL, discName: String,
         clips: [DvdClip], duration: Double) {
        self.isoPath = isoPath
        self.mountPoint = mountPoint
        self.discName = discName
        self.clips = clips
        self.duration = duration
    }

    /// 生成 EDL：每个 VOB 一段，长度按文件自己的 PTS 算。
    func prepare() -> URL? {
        if let edlURL { return edlURL }

        var lines = ["# mpv EDL v0", "!no_chapters"]
        for clip in clips where clip.duration > 0.1 {
            lines.append("\(clip.url.path),0,\(String(format: "%.3f", clip.duration))")
        }
        guard lines.count > 2 else { return nil }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dvplayer-dvd-\(UUID().uuidString).edl")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[Disc] DVD EDL 写入失败：\(error.localizedDescription)")
            return nil
        }
        edlURL = url
        return url
    }

    /// 卸载镜像并删掉临时 EDL。重复调用无副作用。
    func detach() {
        guard !detached else { return }
        detached = true
        if let edlURL {
            try? FileManager.default.removeItem(at: edlURL)
        }
        edlURL = nil
        BluRayDisc.unmount(mountPoint)
    }
}

/// 挂载后的镜像是什么盘：蓝光（BDMV）还是 DVD（VIDEO_TS）。
enum DiscContent {
    case bluray(BluRaySession)
    case dvd(DvdSession)
}

enum BluRayError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
            case .message(let text): return text
        }
    }
}

/// 一张已经挂载好的原盘。sel 一个标题后调 `prepare` 生成 EDL，
/// 播放窗关闭时 `detach` 卸载。
///
/// macOS 随包的 mpv 没有 libbluray（Windows 版有），所以这里不靠 `bd://`：
/// 用 hdiutil 挂载 ISO，自己读 `BDMV/PLAYLIST/*.mpls`，再把里面的
/// `(m2ts, 起始秒, 时长)` 拼成一份 mpv EDL 播放。
final class BluRaySession {
    let isoPath: String
    let mountPoint: URL
    let discName: String
    let titles: [BluRayTitle]
    /// 这张盘的菜单是 BD-J（`BDMV/JAR/*.jar`）。BD-J 菜单要 Java VM +
    /// libbluray 的 BD-J jar；随包的 libbluray 没有，mpv 只能“Playing without
    /// menus”，进菜单会停在菜单背景视频，所以这种盘直接播正片。
    let hasBDJ: Bool

    private var edlURLs: [URL] = []
    private var detached = false

    init(isoPath: String, mountPoint: URL, discName: String, titles: [BluRayTitle],
         hasBDJ: Bool) {
        self.isoPath = isoPath
        self.mountPoint = mountPoint
        self.discName = discName
        self.titles = titles
        self.hasBDJ = hasBDJ
    }

    /// 正片：时长接近最长标题的那几个（2in1 会有两个）。
    func isFeature(_ title: BluRayTitle) -> Bool {
        guard let longest = titles.map(\.duration).max(), longest > 0 else { return false }
        return title.duration >= longest * 0.9
    }

    /// 为标题生成 EDL；路径是挂载点里的 m2ts，播放期间不能卸载。
    func prepare(_ title: BluRayTitle) -> URL? {
        let streamDir = mountPoint.appendingPathComponent("BDMV/STREAM", isDirectory: true)
        var lines = ["# mpv EDL v0", "!no_chapters"]

        for clip in title.clips {
            let file = streamDir.appendingPathComponent(clip.stream)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let start = String(format: "%.3f", max(0, clip.start))
            let length = String(format: "%.3f", max(0.1, clip.duration))
            lines.append("\(file.path),\(start),\(length)")
        }

        // 只有头部两行说明没有可用片段。
        guard lines.count > 2 else { return nil }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dvplayer-disc-\(UUID().uuidString).edl")
        do {
            try lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("[Disc] EDL 写入失败：\(error.localizedDescription)")
            return nil
        }

        edlURLs.append(url)
        return url
    }

    /// 卸载 ISO 并清掉临时 EDL。重复调用无副作用。
    func detach() {
        guard !detached else { return }
        detached = true

        // 切标题会生成多份 EDL，全部清掉。
        for url in edlURLs {
            try? FileManager.default.removeItem(at: url)
        }
        edlURLs.removeAll()

        BluRayDisc.unmount(mountPoint)
    }
}

enum BluRayDisc {
    /// 挂载 ISO、读出标题列表。失败时会把临时挂载点清掉。
    /// 挂载镜像，认出是蓝光（BDMV）还是 DVD（VIDEO_TS）。
    static func open(isoPath: String) throws -> DiscContent {
        guard FileManager.default.fileExists(atPath: isoPath) else {
            throw BluRayError.message("找不到 ISO 文件。")
        }

        let mount = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("dvplayer-disc-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)

        do {
            _ = try run("/usr/bin/hdiutil", [
                "attach", "-readonly", "-nobrowse", "-noautoopen",
                "-mountpoint", mount.path, isoPath,
            ])
        } catch {
            try? FileManager.default.removeItem(at: mount)
            throw BluRayError.message("挂载 ISO 失败：\(error.localizedDescription)")
        }

        do {
            if let bdmv = findBDMV(in: mount) {
                return .bluray(try openBluRay(isoPath: isoPath, mount: mount, bdmv: bdmv))
            }
            if let video = findVideoTS(in: mount) {
                return .dvd(try openDvd(isoPath: isoPath, mount: mount, videoTS: video))
            }
            // 既不是 BDMV 也不是 VIDEO_TS：不是我们认识的蓝光 / DVD 镜像。
            throw BluRayError.message(
                "这张盘里既没有 BDMV 也没有 VIDEO_TS，不是可识别的蓝光 / DVD 镜像。")
        } catch {
            unmount(mount)
            throw error
        }
    }

    /// 读蓝光的 mpls 标题表。
    private static func openBluRay(isoPath: String, mount: URL, bdmv: URL) throws -> BluRaySession {
        let playlistDir = bdmv.appendingPathComponent("PLAYLIST", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: playlistDir, includingPropertiesForKeys: nil)) ?? []
        let playlists = files
            .filter { $0.pathExtension.lowercased() == "mpls" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        var titles: [BluRayTitle] = []
        for (index, file) in playlists.enumerated() {
            guard let data = try? Data(contentsOf: file) else { continue }
            let clips = parsePlaylist(data)
            let duration = clips.reduce(0) { $0 + $1.duration }
            guard !clips.isEmpty, duration > 1 else { continue }

            let mpls = Int(file.deletingPathExtension().lastPathComponent) ?? (index + 1)
            titles.append(BluRayTitle(id: mpls, number: index + 1,
                                      duration: duration, clips: clips,
                                      chapters: parseChapters(data, clips: clips)))
        }

        guard !titles.isEmpty else {
            throw BluRayError.message("没有从这张盘里读到可播放的标题。")
        }

        let name = discName(bdmv: bdmv)
            ?? URL(fileURLWithPath: isoPath).deletingPathExtension().lastPathComponent

        // BD-J 盘点菜单：`BDMV/JAR/*.jar`。这类盘的菜单要 Java VM +
        // libbluray 的 BD-J jar，随包的 libbluray 没有，mpv 会直接
        // “Playing without menus”——进菜单只会停在菜单背景视频。
        let jarDir = bdmv.appendingPathComponent("JAR", isDirectory: true)
        let jars = (try? FileManager.default.contentsOfDirectory(
            at: jarDir, includingPropertiesForKeys: nil)) ?? []
        let hasBDJ = jars.contains { $0.pathExtension.lowercased() == "jar" }

        NSLog("[Disc] mounted \(isoPath) at \(mount.path) titles=\(titles.count) "
              + "bdj=\(hasBDJ)")
        return BluRaySession(isoPath: isoPath, mountPoint: mount,
                             discName: name, titles: titles, hasBDJ: hasBDJ)
    }

    /// 读 DVD：挑主 VTS（非菜单 VOB 总字节最大的一组），读它的 IFO，
    /// 用最长 PGC 的 cell 表把每一卷 VOB 该播多久算出来。
    ///
    /// 为什么不用 PTS 算时长：DVD 的 PTS 在每个 cell 都会重置（一碟里
    /// 分集 / 章节各自从 0 开始），首尾 PTS 相减会得负数或 24 小时。
    /// PGC 的 cell 表里有扇区范围 + BCD 时长，才是真正的播放时长。
    private static func openDvd(isoPath: String, mount: URL, videoTS: URL) throws -> DvdSession {
        let files = (try? FileManager.default.contentsOfDirectory(
            at: videoTS, includingPropertiesForKeys: [.fileSizeKey])) ?? []

        // VTS_01_1.VOB / VTS_01_2.VOB ...；`*_0.VOB` 是菜单 / 入口视频，跳过。
        struct Part { let vts: Int; let part: Int; let url: URL; let sectors: Int }
        var parts: [Part] = []
        for file in files {
            let name = file.lastPathComponent.uppercased()
            guard name.hasPrefix("VTS_"), name.hasSuffix(".VOB") else { continue }
            let bits = name.dropLast(4).split(separator: "_")
            guard bits.count == 3,
                  let vts = Int(bits[1]), let part = Int(bits[2]), part >= 1 else { continue }
            let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size > 0 else { continue }
            parts.append(Part(vts: vts, part: part, url: file, sectors: size / 2048))
        }

        // 主 VTS：非菜单 VOB 加起来最大的一组（花絮 / 菜单不会比正片大）。
        let grouped = Dictionary(grouping: parts, by: \.vts)
        let main = grouped.max { lhs, rhs in
            lhs.value.reduce(0) { $0 + $1.sectors } < rhs.value.reduce(0) { $0 + $1.sectors }
        }?.value ?? []
        let ordered = main.sorted { ($0.vts, $0.part) < ($1.vts, $1.part) }
        guard !ordered.isEmpty, let vtsNumber = ordered.first?.vts else {
            throw BluRayError.message("这张 DVD 镜像里没有可播放的 VOB 文件。")
        }

        // 每一卷 VOB 在 VTS 的扇区域里占哪一段。
        var ranges: [(start: Int, end: Int, url: URL)] = []
        var cursor = 0
        for part in ordered {
            ranges.append((cursor, cursor + part.sectors, part.url))
            cursor += part.sectors
        }

        // 读 IFO 的最长 PGC：cell 扇区 → 落在哪一卷，累加该 cell 的时长。
        let durations = dvdClipDurations(vts: vtsNumber, videoTS: videoTS,
                                         ranges: ranges)
        var clips: [DvdClip] = []
        for range in ranges {
            guard let duration = durations?[range.url], duration > 0.5 else { continue }
            clips.append(DvdClip(url: range.url, duration: duration))
        }

        // IFO 读不出来（非标准盘 / BUP 缺失）：退回 PTS 估算，至少能播。
        if clips.isEmpty {
            NSLog("[Disc] dvd ifo 读不到，退回 PTS 估时长")
            for range in ranges {
                let duration = mpegDuration(range.url)
                guard duration > 0.5 else { continue }
                clips.append(DvdClip(url: range.url, duration: duration))
            }
        }
        guard !clips.isEmpty else {
            throw BluRayError.message("读不到这张 DVD 的视频时长。")
        }

        let name = URL(fileURLWithPath: isoPath).deletingPathExtension().lastPathComponent
        let total = clips.reduce(0) { $0 + $1.duration }
        NSLog("[Disc] dvd \(isoPath) vob=\(clips.count) ifo=\(durations != nil) "
              + "dur=\(Int(total))s")
        return DvdSession(isoPath: isoPath, mountPoint: mount, discName: name,
                          clips: clips, duration: total)
    }

    /// 读 `VTS_xx_0.IFO` 里最长的 PGC，按 cell 扇区把时长分摊到各卷 VOB。
    /// 返回 nil 表示 IFO 结构不认识（调用方退回 PTS 估算）。
    private static func dvdClipDurations(
        vts: Int,
        videoTS: URL,
        ranges: [(start: Int, end: Int, url: URL)]
    ) -> [URL: Double]? {
        let ifo = videoTS.appendingPathComponent(String(format: "VTS_%02d_0.IFO", vts))
        guard let data = try? Data(contentsOf: ifo), data.count > 0x100 else { return nil }

        guard let pgcitSector = be32(data, 0xCC),
              let pgcit = sector(data, pgcitSector),
              let count = be16(data, pgcit),
              count > 0, pgcit + 8 + count * 8 <= data.count else { return nil }

        // 每个 PGC：时长长的当主标题（DVD 的「播放全部」通常最长）。
        var best: (duration: Double, cells: [(first: Int, last: Int, seconds: Double)])?
        for index in 0..<count {
            let srp = pgcit + 8 + index * 8
            // pgc_start_byte 相对 PGCIT 起点（不是相对整个 IFO）。
            guard let start = be32(data, srp + 4) else { continue }
            let pgc = pgcit + start
            guard pgc + 236 <= data.count else { continue }

            let duration = bcdTime(data, pgc + 4)
            guard duration > 0 else { continue }
            guard best == nil || duration > best!.duration else { continue }

            guard let cellOffset = be16(data, pgc + 232) else { continue }
            let cellCount = Int(data[pgc + 3])
            let table = pgc + cellOffset
            var cells: [(Int, Int, Double)] = []
            var valid = true
            for cell in 0..<cellCount {
                let item = table + cell * 24
                guard item + 24 <= data.count,
                      let first = be32(data, item + 8),
                      let last = be32(data, item + 20) else {
                    valid = false
                    break
                }
                cells.append((first, last, bcdTime(data, item + 4)))
            }
            guard valid, !cells.isEmpty else { continue }
            best = (duration, cells)
        }
        guard let pgc = best else { return nil }

        var durations: [URL: Double] = [:]
        for cell in pgc.cells {
            let mid = (cell.first + cell.last) / 2
            guard let range = ranges.first(where: { mid >= $0.start && mid < $0.end }) else {
                continue
            }
            durations[range.url, default: 0] += cell.seconds
        }
        return durations.isEmpty ? nil : durations
    }

    /// IFO 里的扇区号 → 文件内字节偏移（扇区 2048 字节）。
    private static func sector(_ data: Data, _ index: Int) -> Int? {
        let offset = index * 2048
        return offset >= 0 && offset < data.count ? offset : nil
    }

    private static func be16(_ data: Data, _ offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= data.count else { return nil }
        return Int(data[offset]) << 8 | Int(data[offset + 1])
    }

    private static func be32(_ data: Data, _ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= data.count else { return nil }
        return Int(data[offset]) << 24 | Int(data[offset + 1]) << 16
            | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
    }

    /// `dvd_time_t`：BCD 的时 / 分 / 秒 + 帧（帧率在最高两位，忽略）。
    private static func bcdTime(_ data: Data, _ offset: Int) -> Double {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        func bcd(_ byte: UInt8) -> Int { Int(byte >> 4) * 10 + Int(byte & 0x0F) }
        let hour = bcd(data[offset])
        let minute = bcd(data[offset + 1])
        let second = bcd(data[offset + 2])
        guard hour <= 99, minute <= 59, second <= 59 else { return 0 }
        return Double(hour * 3600 + minute * 60 + second)
    }

    /// VOB 的时长：MPEG-PS 的 PES 头里有 PTS，拿第一个和最后一个 PTS 相减。
    /// 只读文件头尾 1 MiB，SMB 上也很快；PTS 是 33 位，回绕补一圈。
    private static func mpegDuration(_ url: URL) -> Double {
        let window = 1 << 20
        guard let handle = try? FileHandle(forReadingFrom: url) else { return 0 }
        defer { try? handle.close() }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size]
            as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { return 0 }

        let head = handle.readData(ofLength: window)
        guard let first = ptsRange(head) else { return 0 }

        var last = first.1
        if size > Int64(window) * 2 {
            try? handle.seek(toOffset: UInt64(size) - UInt64(window))
            if let tail = ptsRange(handle.readData(ofLength: window)) {
                last = max(first.0, tail.1)
            }
        }

        var diff = Double(last) - Double(first.0)
        if diff < 0 { diff += 8_589_934_592 }   // 2^33
        return max(0, diff / 90000)
    }

    /// 一段 MPEG-PS 里的（第一个, 最后一个）PTS（90 kHz）。
    private static func ptsRange(_ data: Data) -> (UInt64, UInt64)? {
        var first: UInt64?
        var last: UInt64 = 0
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var i = 0
            while i + 13 < bytes.count {
                if bytes[i] == 0, bytes[i + 1] == 0, bytes[i + 2] == 1 {
                    let sid = bytes[i + 3]
                    // 视频 / 音频 / 私用流（含 DVD 子图）的 PES，PTS 标志在
                    // 包头第 7 字节的最高位。
                    let isPes = (sid >= 0xC0 && sid <= 0xEF) || sid == 0xBD
                    if isPes, bytes[i + 7] & 0x80 != 0 {
                        let pts = (UInt64(bytes[i + 9] & 0x0E) << 29)
                            | (UInt64(bytes[i + 10]) << 22)
                            | (UInt64(bytes[i + 11] & 0xFE) << 14)
                            | (UInt64(bytes[i + 12]) << 7)
                            | (UInt64(bytes[i + 13] & 0xFE) >> 1)
                        if first == nil { first = pts }
                        last = pts
                    }
                    i += 3
                } else {
                    i += 1
                }
            }
        }
        guard let head = first else { return nil }
        return (head, last)
    }

    static func unmount(_ mount: URL) {
        _ = try? run("/usr/bin/hdiutil", ["detach", mount.path, "-force"])
        try? FileManager.default.removeItem(at: mount)
    }

    /// 崩溃 / 强制退出可能留下已挂载的临时目录，启动时清一遍。
    static func cleanupStaleMounts() {
        let temp = URL(fileURLWithPath: NSTemporaryDirectory())
        let items = (try? FileManager.default.contentsOfDirectory(
            at: temp, includingPropertiesForKeys: [.isDirectoryKey])) ?? []

        for item in items where item.lastPathComponent.hasPrefix("dvplayer-disc-") {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: item.path,
                                                 isDirectory: &isDirectory),
                  isDirectory.boolValue else {
                continue
            }
            unmount(item)
        }
    }

    // MARK: - 私有

    private static func run(_ executable: String, _ args: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        do {
            try process.run()
        } catch {
            throw BluRayError.message(error.localizedDescription)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw BluRayError.message(text.isEmpty
                ? "命令退出码 \(process.terminationStatus)"
                : text.trimmingCharacters(in: .whitespacesAndNewlines))
        }

        return text
    }

    /// ISO 根目录可能是 BDMV，也可能套了一层文件夹（常见于自己打的 ISO）。
    private static func findBDMV(in root: URL) -> URL? {
        let direct = root.appendingPathComponent("BDMV", isDirectory: true)
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }

        let children = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for child in children {
            let nested = child.appendingPathComponent("BDMV", isDirectory: true)
            if FileManager.default.fileExists(atPath: nested.path) {
                return nested
            }
        }

        return nil
    }

    /// 和 BDMV 一样，VIDEO_TS 也可能套一层文件夹。
    private static func findVideoTS(in root: URL) -> URL? {
        let direct = root.appendingPathComponent("VIDEO_TS", isDirectory: true)
        if FileManager.default.fileExists(atPath: direct.path) {
            return direct
        }

        let children = (try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for child in children {
            let nested = child.appendingPathComponent("VIDEO_TS", isDirectory: true)
            if FileManager.default.fileExists(atPath: nested.path) {
                return nested
            }
        }

        return nil
    }

    private static func discName(bdmv: URL) -> String? {
        let meta = bdmv.appendingPathComponent("META/DL", isDirectory: true)
        let files = (try? FileManager.default.contentsOfDirectory(
            at: meta, includingPropertiesForKeys: nil)) ?? []

        for file in files where file.pathExtension.lowercased() == "xml" {
            guard let text = try? String(contentsOf: file, encoding: .utf8),
                  let start = text.range(of: "<di:name>"),
                  let end = text.range(of: "</di:name>",
                                       range: start.upperBound..<text.endIndex) else {
                continue
            }

            let name = String(text[start.upperBound..<end.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !name.isEmpty {
                return name
            }
        }

        return nil
    }

    /// mpls 的 PlayList 段：每个 PlayItem 有 IN_time / OUT_time（45 kHz 刻度），
    /// 所有多字节字段都是大端。
    private static func parsePlaylist(_ data: Data) -> [BluRayClip] {
        guard data.count > 12,
              let playlistStart = data.be32(8),
              let count = data.be16(playlistStart + 6) else {
            return []
        }

        var position = playlistStart + 10
        var clips: [BluRayClip] = []

        for _ in 0..<count {
            guard let length = data.be16(position) else { break }
            let end = position + 2 + length
            guard end <= data.count else { break }

            var cursor = position + 2
            guard cursor + 5 <= data.count else { break }
            let clip = String(data: data[cursor..<cursor + 5], encoding: .ascii)?
                .trimmingCharacters(in: .whitespaces) ?? ""
            cursor += 5 + 4

            guard let flags = data.be16(cursor) else { break }
            cursor += 2
            if flags & 0x10 != 0 {
                cursor += 4      // multi-angle 多出来的 4 字节
            }
            cursor += 1          // STC_sequence_id

            guard let inTime = data.be32(cursor),
                  let outTime = data.be32(cursor + 4),
                  outTime > inTime else {
                position = end
                continue
            }

            let start = Double(inTime) / 45_000.0
            let duration = Double(outTime - inTime) / 45_000.0
            if !clip.isEmpty, duration > 0 {
                clips.append(BluRayClip(stream: clip + ".m2ts",
                                        start: start, duration: duration))
            }

            position = end
        }

        return clips
    }

    /// mpls 的 PlayListMark 段：每条 mark 定长 14 字节，`mark_type == 1` 是章节。
    ///
    /// `mark_time_stamp` 是**源流时间**（相对 PlayItem 的 IN_time，45 kHz），
    /// 不是 playlist 相对时间：真实盘 `00001.mpls` 的 IN 是 600 s、第一条 mark
    /// 也是 600 s，而 libbluray / mpv 报的第一章是 0。换算成 playlist 时间要
    /// 减去该 PlayItem 的 IN、再加上前面各段的时长，这样菜单里的章节时间才能
    /// 直接拿去 seek。
    private static func parseChapters(_ data: Data, clips: [BluRayClip]) -> [BluRayChapter] {
        guard !clips.isEmpty, data.count > 18,
              let markStart = data.be32(12),
              markStart > 0, markStart + 6 <= data.count,
              let count = data.be16(markStart + 4), count > 0 else {
            return []
        }

        // 每个 PlayItem 在 playlist 里的起点。
        var offsets: [Double] = []
        var total = 0.0
        for clip in clips {
            offsets.append(total)
            total += clip.duration
        }

        var times: [Double] = []
        for index in 0..<count {
            let base = markStart + 6 + index * 14
            guard base + 14 <= data.count else { break }
            guard data[base + 1] == 1 else { continue }      // 1 = 章节，2 = link point
            guard let item = data.be16(base + 2), item < clips.count,
                  let stamp = data.be32(base + 4) else { continue }

            let sourceTime = Double(stamp) / 45_000.0
            let time = offsets[item] + (sourceTime - clips[item].start)
            // 片尾那条 mark 就等于时长，放进菜单只会是「点一下就结束」。
            if time > 0.5, time < total - 1 {
                times.append(time)
            }
        }

        return times.sorted().enumerated().map { offset, time in
            BluRayChapter(id: offset + 1, time: time)
        }
    }
}

private extension Data {
    func be16(_ offset: Int) -> Int? {
        guard offset >= 0, offset + 2 <= count else { return nil }
        return (Int(self[offset]) << 8) | Int(self[offset + 1])
    }

    func be32(_ offset: Int) -> Int? {
        guard offset >= 0, offset + 4 <= count else { return nil }
        return (Int(self[offset]) << 24)
            | (Int(self[offset + 1]) << 16)
            | (Int(self[offset + 2]) << 8)
            | Int(self[offset + 3])
    }
}
