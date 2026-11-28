# ADR-0015：Android 存储走 Kotlin VFS + 核心虚拟源

- 状态：已接受
- 日期：2026-11-25

## 背景

桌面端的 SMB / NFS / WebDAV 是「系统挂载后当本地目录扫」：Windows 映射网络驱动器，
macOS 挂载后走同一个本地文件夹源（见 [LOCAL-SOURCE.md](../LOCAL-SOURCE.md) §6）。
Android 没有系统挂载，这条路径直接断。而 `core/media` 的本地源只会调 `std::fs`，
读不了 `smb://`、`nfs://`、`content://`。

## 决策

1. Kotlin 侧实现统一 `Vfs` 接口：`list` / `stat` / `open` / `seek`。
2. 三个实现：
   - SMB2/3 用 smbj；
   - NFS 用 libnfs（JNI 薄封装，仅 AUTH_SYS，NFSv3 / v4）；
   - WebDAV 用 OkHttp（PROPFIND + Range）。
3. `core/media` 新增 vfs 源适配器：壳把目录树 JSON 灌进去，适配器复用
   `sources/local.rs` 的目录树构建与 `SxxExx` / `第 N 集` 认集号逻辑。
   `kind = "vfs"`，但 `dv_source_kinds()` 不返回它（由壳注入，不是用户手填的源类型）。
4. 播放走各协议的 `DataSource`：Media3 侧实现 `DataSource.Factory`，
   mpv 侧用 `mpv_stream_cb_add_ro`；两者共用同一份 VFS 读取。
5. 核心补两个接口：
   - `dv_hub_replace(id, config)`：VFS 重扫后替换同名源。目前没有 remove / replace，
     只能重建整个 hub，会丢其它源的状态；
   - `dv_probe_dovi_bytes(ptr, len)`：VFS / SAF 拿不到路径，
     Kotlin 读前 8MB 传入，判定逻辑仍只在 `core/dovi` 一份。

## 理由

- 把 libsmb2 / libnfs 拉进 Rust，意味着三个桌面平台都要跟着编 C 依赖；
  而桌面端现在靠系统挂载，没有改造动力。
- smbj 与 OkHttp 在 Android 上成熟；libnfs 只包一层 JNI，成本可控。
- 目录树与集号解析已经写在 Rust 里，适配器接收现成的树，不需要在 Kotlin 里重复一套。

## 后果

- 这套 VFS 只有 Android 有；M4 若要收敛到 Rust 再评估。
- NFS 只支持 AUTH_SYS（无 Kerberos）。企业环境的 Kerberos 导出不可用，能力矩阵要标明。
- SMB 不支持 SMB1；老 NAS 需要开 SMB2/3。
- SAF 的 `content://` 给不了路径：播放用 file descriptor，DV 探测走 `dv_probe_dovi_bytes`。
- 加密原盘（AACS / AACS2）不在此列，见 [ADR-0014](0014-android-dual-engine.md) 与
  [BLU-RAY.md](../BLU-RAY.md)。
