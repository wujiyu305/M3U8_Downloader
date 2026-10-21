# M3U8 Downloader

一个原生 SwiftUI 的 macOS 应用，为 [N_m3u8DL-RE](https://github.com/nilaoda/N_m3u8DL-RE) 提供图形界面：粘贴链接、选轨道、下载、合并，并可对已有文件用 ffmpeg 写入元数据。

应用本身不下载任何东西，它启动 N_m3u8DL-RE 引擎作为子进程，并解析引擎的输出来显示进度。

## 功能

- **URL 优先的界面**：窗口一打开就是链接输入框（粘贴 / 选择本地清单 / 清除），下面是按需展开的选项分区：Output、Network、Tracks、Merge & Decrypt、Live、Advanced。
- **下载前选轨道**：先用 `--skip-download` 列出所有轨道，再让你勾选；每个轨道显示编码、HDR、声道、语言等标签。
- **按字节加权的总进度**：引擎是一个流接一个流下载的，总进度条按各流的预估大小（时长 × 码率）加权，不会因为有十几条字幕轨就停在 5%。
- **队列与日志**：右侧队列显示每个任务的进度、当前轨道、速度和剩余时间；底部日志抽屉默认折叠，失败时可一键打开。
- **Metadata 标签页**：对已有文件用 ffmpeg 写入标题、描述、日期和封面，是独立的任务，不依赖某次下载。
- **完成后的操作**：下载完成可在 Finder 中显示，失败可直接查看日志。
- **可靠地停止**：Stop 会先发 SIGTERM，等待片刻后对整棵进程树发 SIGKILL；退出应用会先确认并等进程真正停掉。默认一次只运行一个任务，其余的排队等待。

## 环境要求

| | |
|---|---|
| 系统 | macOS 14.0 及以上，仅 macOS；**仅 Apple 芯片（arm64）**，见下 |
| 构建 | Xcode 27（项目文件格式较新） |
| 引擎 | N_m3u8DL-RE 可执行文件，见下文 |
| ffmpeg | 合并、混流和写元数据时需要，**不随应用打包**，用系统里的，例如 `brew install ffmpeg` |

架构固定为 arm64（`Config/Shared.xcconfig` 里的 `ARCHS`）：内置的引擎默认只编译 arm64，如果应用同时构建 x86_64，嵌入步骤会因为架构对不上而跳过引擎，包里就没有引擎了。要支持 Intel，需要删掉那一行，并在上级仓库里运行 `scripts/build-engine.sh --universal`。

应用**没有开启沙盒**：它需要启动引擎和 ffmpeg 子进程，并写入你选择的任意目录。

## 构建与运行

1. 配置本地标识（见下一节，不配也能构建，只是用占位的 Bundle ID）。
2. 用 Xcode 打开 `M3U8Downloader.xcodeproj`，选 `M3U8Downloader` scheme 运行。

### 本地标识

Bundle ID 前缀和签名团队属于个人信息，不放进项目文件，而是写在一个被 git 忽略的文件里：

```
cp Config/Local.xcconfig.example Config/Local.xcconfig
# 然后编辑 Config/Local.xcconfig，设置 APP_BUNDLE_ID_PREFIX（以及可选的 DEVELOPMENT_TEAM）
```

不创建它时，`Config/Shared.xcconfig` 里的默认值 `com.example` 生效，应用以 `com.example.M3U8Downloader` 的标识构建。

## 引擎和 ffmpeg 从哪里找

应用按下面的顺序找可执行文件，先找到的生效：

1. 设置里手动指定的路径（引擎和 ffmpeg 各有一个）。
2. 应用包里的 `Resources/N_m3u8DL-RE`（仅引擎；ffmpeg 不打包）。
3. 常见安装位置：`/opt/homebrew/bin`、`/usr/local/bin`、`/opt/local/bin`、`/usr/bin`。从 Finder 启动的应用拿不到 shell 的 `PATH`，所以要显式查这些目录。
4. 最后才看 `PATH`。

找不到时应用照常启动，在界面上说明缺什么以及怎么补，不会让构建失败。

### 把引擎打进应用包

这个应用最初放在 “N_m3u8DL-RE 命令生成器” 仓库的 `macos/M3U8Downloader` 下，引擎的构建和嵌入脚本在那个仓库里：

- `scripts/build-engine.sh` 用 .NET 10 SDK 编译引擎（只在构建时需要，产物是自包含的原生程序）。
- `scripts/embed-engine.sh` 由工程里的 Run Script 阶段调用，把引擎复制进应用包并重新签名。

单独使用这个仓库时没有这两个脚本，Run Script 阶段只会给出警告，应用仍能构建，引擎需要在设置里指定一个现成的可执行文件。

## 常见问题

**下载失败，提示 `Segment count check not pass, total: 774, downloaded: 773.`**

有一个分片没有完整下载。先看日志里同一个分片是不是每次重试都失败（例如反复出现同样的 `The response ended prematurely, with at least N additional bytes expected`）：

- 是的话，多半是服务器上那个分片本身损坏了，重试、加线程、加重试次数都没有用。实测过一个 Apple 活动视频：CDN 对其中一个分片声明了 2.4 MB，却只返回 1 个字节就断开，换 HTTP/1.1、Range 请求、绕缓存都一样，34 个视频变体里有 5 个在同一位置损坏，其余正常。
- 办法一：在轨道列表里换一个流，比如同分辨率的另一个码率。
- 办法二：在 Advanced 里把 Check segment count 关掉，引擎会跳过检查并合并出文件，但缺少那一个分片，画面会有几秒跳变。
- 如果每次失败的分片都不同，那才是网络问题，可以调低 Threads、调高 Retries。

**顶部出现橙色或红色的横幅**

红色表示找不到下载引擎，橙色表示找不到 ffmpeg（没有它仍可下载，只是不能合并和写元数据）。点 “How to fix” 查看处理方法，处理后点 “Check again”。

## 测试

```
xcodebuild -project M3U8Downloader.xcodeproj -scheme M3U8Downloader test
```

- 使用 Swift Testing，约 330 个单元测试；解析器用的是真实引擎输出的抓取文件（`M3U8DownloaderTests/Fixtures/`），不要手工修改它们。
- 有若干测试会启动真实子进程（`/bin/sh` 脚本冒充引擎和 ffmpeg）来验证停止、排队和失败处理。
- UI 测试只是启动应用；如果 Xcode 里正有一个调试中的实例在运行，`XCUIApplication` 终止不了它，测试会失败。

## 目录

```
Config/                       本地标识（Local.xcconfig 被忽略）
M3U8Downloader/
  Core/                       选项模型、参数构建、进程管理、引擎输出解析，不含 UI
  Views/                      SwiftUI 界面
  ContentView.swift           窗口布局、队列、日志抽屉
  AppIcon.icon/               Icon Composer 格式的图标，图层是 SVG
M3U8DownloaderTests/          单元测试与引擎输出样本
M3U8DownloaderUITests/        启动测试
```

## 给开发者

各目录下的 `AGENTS.md` 记录了这个项目里实测得到的、不显然的事实和踩过的坑，动对应区域之前请先读：

- `M3U8Downloader/Core/AGENTS.md`：引擎输出的格式和解析、进程生命周期、进度加权、凭据处理。
- `M3U8Downloader/AGENTS.md`：窗口布局、SwiftUI 的注意点、图标、退出行为。
- `M3U8DownloaderTests/AGENTS.md`：测试夹具与写测试的规则。

代码格式化用 Xcode 自带的 `swift-format`，配置在 `.swift-format`（4 空格缩进）：

```
xcrun swift-format format -i --configuration .swift-format <文件>
xcrun swift-format lint --configuration .swift-format --recursive M3U8Downloader M3U8DownloaderTests
```
