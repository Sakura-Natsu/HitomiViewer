<div align="center">

<img src="hitomi_reader/assets/icon.png" width="128" alt="HitomiViewer 图标">

# HitomiViewer

hitomi.la 的非官方第三方客户端，界面与操作习惯参照 EhViewer，基于 Flutter，支持 **Android** 与 **Windows**。

[![CI](https://github.com/Sakura-Natsu/HitomiViewer/actions/workflows/ci.yml/badge.svg)](https://github.com/Sakura-Natsu/HitomiViewer/actions/workflows/ci.yml)
![平台](https://img.shields.io/badge/平台-Android%20%7C%20Windows-blue)
![Flutter](https://img.shields.io/badge/Flutter-3.38%2B-02569B?logo=flutter)
[![许可](https://img.shields.io/badge/许可-MIT-green)](LICENSE)

*An unofficial hitomi.la client for Android and Windows, built with Flutter — EhViewer-style navigation, Chinese tag translations, and a full-featured manga reader.*

</div>

> [!WARNING]
> 本项目与 hitomi.la 没有任何关联，所有内容均来自该网站。网站内容可能包含成人内容，请仅在年满 18 周岁且当地法律允许的情况下使用。首次启动时应用会要求确认年龄。

## 功能亮点

- **熟悉的操作方式**：侧边栏导航、胶囊形搜索栏、右侧快速搜索，与 EhViewer 一致；搜索栏随滚动收起，往上轻滑即出现。
- **好用的搜索**：标题和标签可以混合输入，标签联想支持中文（「巨乳」→ `female:big breasts`），可叠加多个包含 / 排除条件；粘贴画廊链接直接打开。
- **中文标签**：使用 [EhTagTranslation](https://github.com/EhTagTranslation/Database) 数据库，列表、详情、搜索条件都显示中文。
- **完整的阅读器**：从左到右 / 从右到左 / 竖向滚动，单页 / 双页 / 自动，双指缩放，裁切白边，缩略图跳页，自动翻页，音量键翻页，长按保存图片。
- **收藏、历史、下载**：本地保存，收藏支持与搜索相同的标题 + 标签筛选；下载支持暂停、断点续传，离线阅读。
- **网络友好**：支持系统代理 / 手动 HTTP 代理，标题搜索做了大量提速。

## 安装

在 [Releases](https://github.com/Sakura-Natsu/HitomiViewer/releases) 页面下载：

- **Android**：`HitomiViewer-版本号.apk`（Android 7.0 及以上）。此类应用无法上架主流应用商店，需要自行侧载安装。
- **Windows**：`HitomiViewer-版本号-windows-x64.zip`，解压后运行 `HitomiViewer.exe`（Windows 10 及以上，x64）。

也可以按下文的说明从源码构建。

**网络说明**：在无法直连 hitomi.la 的网络环境中，

- Windows 端会自动使用系统代理（兼容 Clash 等软件的“系统代理”模式）；
- Android 端请在 *设置 → 网络 → 代理* 中填写 HTTP 代理，例如局域网内电脑上 Clash 的混合端口（需开启“允许局域网连接”）。设置页可以测试连接。

## 功能说明

<details>
<summary><b>界面与导航</b></summary>

- 主页顶部是胶囊形搜索栏：左边 ☰ 打开侧边栏，右边是快速搜索和列表 / 网格切换。
- 搜索栏和下面的筛选栏随滚动收起：往下滑时跟着内容滑走，不占浏览空间；在任意位置往上轻滑就会完整出现，不用回到顶部。
- 侧边栏平时隐藏，点 ☰ 或从屏幕左边缘右滑打开：主页、热门（默认今日人气，可切换本周 / 本月 / 年度）、收藏、历史、下载、设置，以及标签目录。
- 不在主页时，返回键先回到主页。
- 快速搜索在右侧抽屉里（点搜索栏的书签按钮或从右边缘左滑），点 + 保存当前搜索。

</details>

<details>
<summary><b>浏览与搜索</b></summary>

- 排序：最新上传、发布日期、今日 / 本周 / 本月 / 年度热门、随机；可按语言筛选；列表和网格两种视图，无限滚动。
- 输入框里的文字就是标题条件，直接输入或粘贴标题回车即可。标题匹配比网站宽松：会自动处理中日文标题里的标点，索引中没有的词会被忽略并在结果上方提示。
- 输入标签名（中文或英文，如「巨乳」「big brea」）会联想标签，显示中文名、英文原名和作品数。点选后正在输入的这一段变成标签条件，前面的标题词保留，可以一边打标题一边叠加标签。
- 已选标签点按可切换「包含 / 排除」，联想项右侧也可以直接选择包含或排除。
- 粘贴画廊链接或 ID 可以直接打开。
- 搜索页显示快速搜索、最近使用的标签和搜索历史。
- 在画廊详情页长按标签：查看中文释义，「加入当前搜索」「从当前搜索中排除」「组合筛选…」「屏蔽」。
- 仍支持网站的高级语法，例如 `female:sole_female language:chinese -male:yaoi`。
- 屏蔽标签：含有这些标签的画廊不会显示在列表中，添加时同样有中文联想。
- 标签目录：按类型和首字母浏览全部标签。

</details>

<details>
<summary><b>中文标签</b></summary>

- 数据来自 [EhTagTranslation](https://github.com/EhTagTranslation/Database)，约 4.4 万条。
- 首次启动时下载（约 1.3 MB，优先使用 jsDelivr 镜像，GitHub 备用），之后每天检查一次更新；不随安装包分发。
- 列表、详情页和搜索条件都显示中文，可在设置中关闭。
- 网站的标签联想结果在本地缓存 7 天。

</details>

<details>
<summary><b>阅读器</b></summary>

- 从左到右、从右到左（日漫）、竖向滚动三种模式。
- 翻页模式可选单页、双页或自动（横屏双页）：封面可单独显示，横向的跨页图单独占一屏，两页向中缝对齐。
- 双击或双指缩放，竖向模式也可以，放大后单指仍能上下滚动。
- 点击屏幕两侧翻页（第一次打开时显示点击区域说明），可关闭翻页动画；Android 可用音量键翻页，可反转。
- 底部面板：进度条跳页（松手后才跳转）、缩略图跳页、自动翻页（1–30 秒）、单双页切换、阅读设置。
- 裁切白边：加载图片时检测四周的白边或纯黑边，在图片显示前完成；边上的页码不影响裁切，暗色画面和大片留白中的小图不裁；竖向模式下页面高度随之变化，但滚动位置会同步修正，画面不跳动。
- 长按（桌面端右键）页面：保存图片（Android 存到相册 `图片/HitomiViewer`，Windows 存到 `图片\HitomiViewer`）、重新加载本页。
- 屏幕常亮、降低亮度（叠加遮罩，可比系统最低亮度更暗）、锁定屏幕方向（Android）。
- 角落显示页码、时间和电量；呼出菜单时只露出状态栏，画面不会重新布局。
- 预加载后续页面，记住阅读进度。
- 桌面端：方向键 / PageUp / PageDown / 空格 / Home / End 翻页，Enter 或 M 打开菜单，Esc 返回；滚轮翻页，Ctrl + 滚轮缩放；竖向模式下 Ctrl + 滚轮（或 Ctrl + = / - / 0）调整图片宽度。

</details>

<details>
<summary><b>收藏、历史、下载</b></summary>

- 收藏与历史保存在本地 JSON。收藏的搜索与普通搜索相同：标题关键词（也匹配日文标题、作者名和 ID）加上包含 / 排除的标签条件。
- 下载原图供离线阅读，支持暂停、继续、断点续传；已下载的画廊阅读时优先读取本地文件。
- 图片服务器临时限流（503 / 429）时会多次重试，第一轮结束后再逐页补下失败的页面。
- 图片缓存到磁盘，可设置上限并自动清理。

</details>

## 从源码构建

需要 [Flutter](https://docs.flutter.dev/get-started/install) 3.38 或更高版本（开发时使用 3.47）。

```bash
git clone https://github.com/Sakura-Natsu/HitomiViewer.git
cd HitomiViewer/hitomi_reader
flutter pub get
flutter run            # 连接的设备或 Windows 桌面
```

构建发布版：

```bash
# Android：输出 build/app/outputs/flutter-apk/app-release.apk（包含所有 CPU 架构，约 55 MB）
flutter build apk --release
# 按架构拆分，arm64 包约 20 MB
flutter build apk --release --split-per-abi

# Windows：输出 build/windows/x64/runner/Release/（整个文件夹一起分发）
flutter build windows --release
```

> [!NOTE]
> Android 发布版目前使用 debug 签名。自行分发前请在 `hitomi_reader/android/app/build.gradle.kts` 中配置自己的签名；不同签名的安装包不能互相覆盖安装。

应用图标由 `hitomi_reader/tool/make_icons.py` 从 `tool/icon_source.webp` 生成（需要 Python、Pillow 和 numpy）。

## 项目结构

```
HitomiViewer/
├─ hitomi_api/          协议层：纯 Dart 包，不依赖 Flutter
│  ├─ lib/src/hitomi.dart           请求、gg.js 图片规则、language_support.js
│  ├─ lib/src/gallery_manager.dart  nozomi 索引分页、多标签交集、标题搜索
│  ├─ lib/src/index_provider.dart   远程 B 树索引（HTTP Range）
│  ├─ lib/src/tag_manager.dart      标签解析、联想、标签目录、标签语言
│  ├─ lib/src/gallery_search.dart   给 UI 用的分页搜索
│  ├─ lib/io.dart                   可复用连接的 HTTP 代理客户端
│  └─ test/                         单元测试 + 真实服务器测试
└─ hitomi_reader/       Flutter 应用（HitomiViewer）
   ├─ lib/services/     HTTP 客户端、图片缓存、下载、收藏 / 历史、设置、中文标签库、标签联想、
   │                    白边检测（crop.dart）、屏幕常亮 / 电量 / 保存图片（device.dart）
   ├─ lib/pages/        浏览 / 搜索、详情、阅读器、收藏、历史、下载、设置、标签目录
   │  └─ reader/        阅读器的分屏、缩放、缩略图、设置面板、点击区域说明
   ├─ lib/widgets/      列表、卡片、图片、侧边栏、随滚动收起的顶栏、标签联想
   ├─ test/             单元测试与组件测试
   ├─ integration_test/ 端到端测试（真实网络，自动截图）
   └─ tool/             图标生成脚本
```

协议层与界面分开：网站改版时，一般只需要修改 `hitomi_api`。

## 测试

```bash
# 协议层单元测试（离线）
cd hitomi_api && dart test

# 协议层真实服务器测试（需要网络）
cd hitomi_api && dart test --run-skipped -t live test/live_test.dart

# 应用单元测试与组件测试（离线）
cd hitomi_reader && flutter test

# 端到端测试：在 Windows 上走一遍主要流程并截图（需要网络，会读写本机应用数据，结束后清理）
cd hitomi_reader && flutter test integration_test/app_test.dart -d windows --dart-define=SHOT_DIR=../shots
```

## 技术说明

### 与 node-hitomi 的差异

协议层参考 [node-hitomi](https://github.com/H2Owater425/node-hitomi) 用 Dart 重写。移植时对照了网站当前的 `common.js`、`search.js`、`gg.js` 和 `language_support.js`，修正了参考实现中的几个问题：

| 问题 | node-hitomi 9.2.0 | 本项目 |
| :-- | :-- | :-- |
| 语言位掩码 | 写死 43 种语言，网站已新增 `khmer`（第 15 位）和 `textless narrative`（第 29 位），导致之后的语言整体错位（例如查不到 chinese） | 运行时读取 `language_support.js`，内置表同步更新 |
| 排除语言标签 | 没有正向语言时，`-language:xx` 会请求 `index-all`，结果被清空 | 请求该语言自己的索引 |
| gg.js 解析 | 假设命中 case 时 `o` 的值为默认值取反 | 同时解析默认值和 case 分支中的值 |
| nozomi 文件 404 | 抛出异常 | 与网站一致，视为空结果 |
| 标签联想中的空格 | 未处理 | 与网站一致，编码为 `_` |
| 多标签查询 | 逐个串行请求 | 并发请求；如果有非语言标签，就以它作为基准集合，避免下载整个语言索引 |
| 标题搜索 | 只按空格分词，任一词不在索引中就没有结果，粘贴带全角标点的中日文标题基本搜不到 | 宽松匹配：依次尝试原词、去掉首尾标点、按中间标点拆分，仍找不到的词忽略；`list()` 保持与网站一致的严格行为 |
| 标题搜索速度 | 每个词沿 B 树逐层单独请求（约 7 层） | 所有词同一层的节点合并为一次 multi-range 请求；打开搜索页时预取上三层；输入时提前查询；结果按索引版本缓存；交集已足够小时跳过 `no`、`ga` 这类超常见词 |
| 搜索语句解析 | `Re:Zero` 这类带冒号的标题词会被丢弃 | 类型无法识别的词作为标题词保留 |

另外，gg.js 中的路径前缀（`b: '...'`）大约每小时变化一次，原图返回 404 时会强制刷新 gg.js 后重试。

### HTTP 代理的性能问题

dart:io 自带的 HTTP 代理支持（`findProxy` 返回 `PROXY host:port`）有缺陷：HTTPS 隧道建立后被登记在目标主机下，而查找空闲连接时用的是代理地址，所以连接永远不会被复用——

- 每个请求都要重新做一次 TLS 握手，实测从约 0.24 秒变成约 0.8 秒；
- 设置 `maxConnectionsPerHost` 后还会卡死。

`hitomi_api/lib/io.dart` 的 `createProxyHttpClient` 改为在 `connectionFactory` 中自己完成 `CONNECT` 和 TLS 握手，连接可以正常复用。

## 已知限制

- 暂不能在应用内播放视频画廊（anime 类型），只能复制视频地址。
- Flutter 不能原生解码 AVIF，图片统一使用 WebP。
- 复杂查询（多个标签、排除标签、标题关键词、随机排序）需要先下载完整的 nozomi 索引再在本地求交集，无语言限制时数据量可达数 MB。
- 标题搜索需要逐级查询网站的 B 树索引：冷启动约 1.5～2.5 秒，打开搜索页预热后约 1 秒；输入后稍作停顿再回车（这期间会提前查询），结果几乎立即出现。
- 刚上传的作品要等网站更新标题索引后才能按标题搜到；按标签浏览不受影响。
- 只在 Android 与 Windows 上测试过，其他平台未适配。

## 致谢

- [node-hitomi](https://github.com/H2Owater425/node-hitomi)：协议实现的参考（MIT 许可，许可证见 [`hitomi_api/LICENSE.node-hitomi`](hitomi_api/LICENSE.node-hitomi)）。
- [EhTagTranslation/Database](https://github.com/EhTagTranslation/Database)：中文标签数据（[CC BY-NC-SA 3.0](https://creativecommons.org/licenses/by-nc-sa/3.0/)，仅限非商业使用；应用在运行时下载，不随本仓库或安装包分发）。
- EhViewer：界面与交互设计的参考。

## 许可

本项目代码以 [MIT 许可](LICENSE) 发布。中文标签数据不属于本项目，使用时须遵守其自身的许可。

本项目仅供学习与交流，与 hitomi.la 及上述项目均无关联。使用者须自行承担使用本软件的一切后果。
