# 打包时注入的凭据

有些凭据只应该存在于开发和打包环境：不进仓库、也不让用户填。目前是弹幕
（弹弹play）的 AppId / AppSecret —— 弹弹play 要求客户端内置一份，让每个用户
自己去开放平台申请既麻烦又不现实。

做法：**打包时**从本地密钥文件读出来写进产物，运行时从产物里读。仓库里、
`settings.json` 里都不出现，设置页也没有输入框。

## 本地密钥文件

两端读同一种格式，默认位置 `~/.config/dvplayer/danmaku.env`
（Windows 的 `~` 是 `%USERPROFILE%`）：

```env
# 弹弹play 开放平台 DevCenter → 应用管理 里拿到的一对
DANMAKU_APP_ID=xxxxxxxx
DANMAKU_APP_SECRET=yyyyyyyy
```

只建一次，别提交：

```bash
mkdir -p ~/.config/dvplayer && chmod 700 ~/.config/dvplayer
printf 'DANMAKU_APP_ID=%s\nDANMAKU_APP_SECRET=%s\n' "$ID" "$SECRET" \
    > ~/.config/dvplayer/danmaku.env
chmod 600 ~/.config/dvplayer/danmaku.env
```

取值顺序：`DVPLAYER_DANMAKU_APP_ID` / `DVPLAYER_DANMAKU_APP_SECRET` 环境变量 >
`DVPLAYER_DANMAKU_ENV` 指定的文件 > 默认路径。缺项就当作空。

## macOS

`apps/macos/DvPlayer/build.sh` 把两个值写进产物的 `Info.plist`
（`DVDanmakuAppId` / `DVDanmakuAppSecret`），运行时由
`Sources/DvCore/DanmakuCredential.swift` 从 `Bundle.main` 读。

- 打包：`apps/macos/packaging/build-release.sh`（内部调 `build.sh`），日志里会有
  `-- 弹幕凭据：已注入（AppId xxxx…）`；找不到就是
  `-- 弹幕凭据：没有找到 …，这个包不带弹幕`。
- 直接 `swift build` 出来的二进制没有 bundle，读不到键 → 弹幕关闭（日志一行，
  不报错、不联网）。
- CI：仓库 Secrets 里配 `DVPLAYER_DANMAKU_APP_ID` / `DVPLAYER_DANMAKU_APP_SECRET`，
  workflow 会传进 `build.sh`；没配就打空包，行为和开发构建一样。

## Windows

`apps/windows/packaging/build-release.ps1` 读同一个文件，用
`dotnet publish -p:DanmakuAppId=… -p:DanmakuAppSecret=…` 变成程序集元数据
（`DvPlayer.csproj` 里的 `AssemblyAttribute`），运行时由
`Services/DanmakuCredential.cs` 反射读出。

- 普通 `dotnet build` 没有这两个属性 → 弹幕关闭。想在本机看弹幕就显式带上：

  ```powershell
  dotnet build -c Release -p:DanmakuAppId=... -p:DanmakuAppSecret=...
  ```

- `-SkipPublish` 复用上一次的 payload，凭据沿用上次打包时的值。

## 换凭据

改 `danmaku.env` 之后重新打包；用户在设置里没有任何缓存，升级包立刻生效。
旧版本 `settings.json` 里残留的 `danmakuAppId` / `danmakuAppSecret` 会被忽略
（解码时不再读），下一次保存就消失。
