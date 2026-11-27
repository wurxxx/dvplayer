# 打包时注入的凭据

有些凭据只应该存在于开发和打包环境：不进仓库、也不让用户填。目前有两类：

- 弹幕（弹弹play）的 AppId / AppSecret —— 弹弹play 要求客户端内置一份，让每个用户
  自己去开放平台申请既麻烦又不现实。
- Trakt 的 Client ID —— 用户只需要在设置页点「连接 Trakt」（设备码授权）；
  Client ID 是「哪个应用在请求」，由打包方注册一次。PKCE 应用没有 Client Secret。

做法：**打包时**从本地密钥文件读出来写进产物，运行时从产物里读。仓库里、
`settings.json` 里都不出现，设置页也没有输入框（开发构建例外，见下）。

## 本地密钥文件

两端读同一种格式，默认位置 `~/.config/dvplayer/danmaku.env`
（Windows 的 `~` 是 `%USERPROFILE%`）：

```env
# 弹弹play 开放平台 DevCenter → 应用管理 里拿到的一对
DANMAKU_APP_ID=xxxxxxxx
DANMAKU_APP_SECRET=yyyyyyyy
```

Trakt 放在同目录的 `trakt.env`：

```env
# Trakt 应用页面的 Client ID；PKCE 应用没有 Client Secret，这一行可以不要
TRAKT_CLIENT_ID=xxxxxxxx
TRAKT_CLIENT_SECRET=
```

只建一次，别提交：

```bash
mkdir -p ~/.config/dvplayer && chmod 700 ~/.config/dvplayer
printf 'DANMAKU_APP_ID=%s\nDANMAKU_APP_SECRET=%s\n' "$ID" "$SECRET" \
    > ~/.config/dvplayer/danmaku.env
chmod 600 ~/.config/dvplayer/danmaku.env

printf 'TRAKT_CLIENT_ID=%s\n' "$TRAKT_ID" > ~/.config/dvplayer/trakt.env
chmod 600 ~/.config/dvplayer/trakt.env
```

取值顺序：`DVPLAYER_DANMAKU_APP_ID` / `DVPLAYER_DANMAKU_APP_SECRET`（Trakt 对应
`DVPLAYER_TRAKT_CLIENT_ID` / `DVPLAYER_TRAKT_CLIENT_SECRET`）环境变量 >
`DVPLAYER_DANMAKU_ENV` / `DVPLAYER_TRAKT_ENV` 指定的文件 > 默认路径。缺项就当作空。

## macOS

`apps/macos/DvPlayer/build.sh` 把值写进产物的 `Info.plist`
（`DVDanmakuAppId` / `DVDanmakuAppSecret` / `DVTraktClientId` / `DVTraktClientSecret`），
运行时由 `Sources/DvCore/DanmakuCredential.swift`、`Sources/DvPlayer/Trakt.swift`
从 `Bundle.main` 读。

- 打包：`apps/macos/packaging/build-release.sh`（内部调 `build.sh`），日志里会有
  `-- 弹幕凭据：已注入（AppId xxxx…）` / `-- Trakt 凭据：已注入（Client xxxx…）`；
  找不到就是 `-- … 没有找到 …，这个包不带 …`。
- 直接 `swift build` 出来的二进制没有 bundle，读不到键 → 弹幕 / Trakt 关闭。
- CI：仓库 Secrets 里配 `DVPLAYER_DANMAKU_APP_ID` / `DVPLAYER_DANMAKU_APP_SECRET`，
  workflow 会传进 `build.sh`；没配就打空包，行为和开发构建一样。

## Windows

`apps/windows/packaging/build-release.ps1` 读同一批文件，用
`dotnet publish -p:DanmakuAppId=… -p:DanmakuAppSecret=… -p:TraktClientId=…`
变成程序集元数据（`DvPlayer.csproj` 里的 `AssemblyAttribute`），运行时由
`Services/DanmakuCredential.cs`、`Services/TraktCredential.cs` 反射读出。

- 本机开发构建也想和正式包一样（设置页不出现 Client ID / Secret 输入框），
  只要把 `trakt.env` / `danmaku.env` 放到 `%USERPROFILE%\.config\dvplayer\`
  （和 macOS 同一份文件），`DvPlayer.csproj` 在求值阶段自动读出来注入，
  普通 `dotnet build` / `dotnet publish` 直接生效，不用先跑脚本。
  文件在仓库外面，不会被提交；没有任何 env 文件时就回退成空凭据。
  换过 env 内容后要 `dotnet build -t:Rebuild`（增量编译不会重写程序集属性）。

- 打包脚本 / CI 用 `-p:` 传值时优先级更高，会盖过 env 文件：

  ```powershell
  dotnet publish -c Release -p:TraktClientId=... -p:TraktClientSecret=...
  ```

- 正式包内置 Client ID 后，设置页只有「连接 Trakt」按钮、状态和自动同步开关，
  没有输入框。
- `-SkipPublish` 复用上一次的 payload，凭据沿用上次打包时的值。

## 换凭据

改 `danmaku.env` / `trakt.env` 之后重新打包；用户在设置里没有任何缓存，升级包
立刻生效。旧版本 `settings.json` 里残留的 `danmakuAppId` / `danmakuAppSecret`
会被忽略（解码时不再读），下一次保存就消失。Trakt 的设置页手填值仍然优先于
内置值，方便自建应用的开发者。
