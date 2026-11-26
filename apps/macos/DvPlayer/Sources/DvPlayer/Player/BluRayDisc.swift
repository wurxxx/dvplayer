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

    private var edlURLs: [URL] = []
    private var detached = false

    init(isoPath: String, mountPoint: URL, discName: String, titles: [BluRayTitle]) {
        self.isoPath = isoPath
        self.mountPoint = mountPoint
        self.discName = discName
        self.titles = titles
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
    static func open(isoPath: String) throws -> BluRaySession {
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
            guard let bdmv = findBDMV(in: mount) else {
                throw BluRayError.message("这张盘里没有 BDMV 目录。")
            }

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
            NSLog("[Disc] mounted \(isoPath) at \(mount.path) titles=\(titles.count)")
            return BluRaySession(isoPath: isoPath, mountPoint: mount,
                                 discName: name, titles: titles)
        } catch {
            unmount(mount)
            throw error
        }
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
