// 把 libmpv 的 C 头文件转给 Swift。module.modulemap 指向这里。
//
// 为什么写绝对路径：libmpv 的头文件在 SwiftPM 包外（仓库的 `prefix/include`），
// 而 SwiftPM 的 `headerSearchPath` 不允许包外路径、`cSettings` 的 `-I` 又赶不上
// module map 解析阶段（会报 `'mpv/client.h' file not found`）。
//
// 换机器 / 挪仓库位置时改下面三行（`apps/macos/DvPlayer/build.sh` 会检查并自动修）。
#ifndef DVPLAYER_MPV_BRIDGE_H
#define DVPLAYER_MPV_BRIDGE_H

#include "/Volumes/data/dev/workspace/dvplayer/prefix/include/mpv/client.h"
#include "/Volumes/data/dev/workspace/dvplayer/prefix/include/mpv/render.h"
#include "/Volumes/data/dev/workspace/dvplayer/prefix/include/mpv/render_gl.h"

#endif
