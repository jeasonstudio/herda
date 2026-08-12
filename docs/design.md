# herdr macOS 原生客户端原型 — 设计文档

日期：2026-08-07
状态：设计已确认，待转实现计划

## 1. 背景与目标

herdr 是一个终端 agent 运行时：后台 server 持有一批 PTY，coding agent（claude / codex / cursor 等）跑在里面，TUI 客户端只是其中一个前端。

本项目做一个 macOS 原生客户端原型：**spaces/agents 用原生 UI 呈现，终端区自己用 Core Text 绘制**，并自带内嵌的 herdr runtime。

**定位：探索性原型。** 目标是尽快摸到"原生 UI + herdr runtime"的真实手感，判断值不值得继续投入。代码可丢弃。不做签名、公证、自动更新、多用户边界情况。

**完成度：demo 级。** 能拉起 server、跑一个 claude、打字有回应、侧边栏能看到 agent 状态即可。崩溃就重启，不做恢复。

## 2. 已验证的前提

以下结论来自对 herdr 源码的调研和一个已跑通的外部客户端探针（`.local/probe`，零依赖 Rust，手写 bincode）。

**协议是客户端中立的，且已在为非 TUI 客户端做准备：**

- `ClientMessage::InputEvents`（`src/protocol/wire.rs:113`）注释原文："Structured input events from platform clients that do not expose Unix-style raw bytes." 提供语义化的 `Key` / `Mouse` / `Paste` / `TextCommit` / `FocusGained/Lost`，无需把 `NSEvent` 翻译成 ANSI 转义序列。
- `RenderEncoding::SemanticFrame` 提供结构化 cell grid（`FrameData`：`Vec<CellData>` + cursor + hyperlinks + kitty graphics），而非 ANSI 字节流。
- `ClientLaunchMode` / `AttachTerminal` / `ObserveTerminal` / `ControlTerminal` 支持 per-pane 订阅。
- JSON API（`src/api/`）覆盖 workspace / tab / pane / agent / worktree / plugin，含 `events.subscribe` 实时事件，有 JSON Schema（`docs/next/api/herdr-api.schema.json`）。
- 项目自身的架构方向支持这件事。`CLAUDE.md`："Herdr is migrating toward a server-owned runtime protocol with the TUI as one client."

**探针实测结论：**

- 握手成功，`PROTOCOL_VERSION = 19`，编码协商为 `SemanticFrame`。
- 拿到的 grid 与 `herdr pane read` 输出**逐字符一致**；lazygit 全屏 TUI（圆角边框、面板、分支名、commit）完整重建。
- 三种颜色编码均正确解码：`named` / `indexed` / `rgb`。
- 渲染尺寸**由客户端声明决定**：声明 100×30 即得 100×30，且目标 pane 的真实尺寸（64 行）在探针运行前后不变——只读 observe 对其他客户端零干扰。

**VT 解析在 server 侧，客户端拿到的是渲染结果。** `ServerMessage` 没有 raw PTY 透传变体。因此不应引入完整终端 emulator（如 SwiftTerm），否则是双重解析；正确做法是实现一个 cell grid 渲染器。

**关键风险（实测确认）：宽字符占位 cell 无任何标记。**

```
20: "更" bytes=[230,155,180] skip=false
21: " "  bytes=[32]          skip=false   ← 占位
36: "从" bytes=[228,187,142] skip=false
37: " "  bytes=[32]          skip=false   ← 占位
38: " "  bytes=[32]          skip=false   ← 真正的空格
```

占位 cell 就是普通空格，`skip` 恒为 `false`（该字段是 ratatui 的 diff 语义，不是宽字符标记）。协议在数据上不区分占位 cell 与真空格，客户端必须自行判断显示宽度。

## 3. 关键决策记录

| 决策 | 选择 | 理由 |
|---|---|---|
| 产品形态 | 自带 runtime 的独立 app | binary 与 app 一起版本化，消除协议版本漂移 |
| 布局语义 | **server 排版 + 原生外壳** | herdr sidebar 设 `Hidden`，App 模式拿整块终端区 grid。split/zoom/焦点/prefix key 全部免费且与 TUI 行为一致，布局子系统工作量为零 |
| 协议编解码 | 纯 Swift 手写 bincode | 单一 Xcode 工程，无 Rust 构建步骤。探针已证明约 100 行足够。自带 runtime 使版本 pin 在一起，手写的主要风险（漂移）已消除 |
| 渲染技术 | Core Text + AppKit `NSView` | 按行合并相同属性的 cell 成 run 绘制，背景色单独填矩形（iTerm2 / Alacritty CPU 模式的标准思路）。Metal 对原型是过度工程 |
| 窗口 chrome | **只有终端浮起 + theme 实色** | sidebar 与窗口底同层同色、贴左边缘、铺满高度；只有终端是一张圆角卡片浮在这一面上。先做过双卡片（两者各一张卡片），实际观感把窗口切得太碎，退回单卡片。表面不用 Liquid Glass：终端正文要长时间阅读，半透明会让对比度随桌面壁纸浮动，且 18 个实色主题会降格成一层 tint。形态全部自绘，不依赖 macOS 26 API |
| 分隔线 / 描边取色 | **相对所在的那个面派生**（`hairline(on:)`） | 不能一律用 `panelBackground` 派生的那条:`windowBackground` 也从它派生、往同一方向（黑）走，两者会收敛。实测亮色主题下差只有 0–6，`kanagawa-lotus` 为 0——卡片描边与 sidebar 分隔线都会消失。间距用 8pt 网格（HIG）|
| deployment target | macOS 26 | 不是技术必需 —— 实测把它降到 14.0 代码照样编译（`ConcentricRectangle` 被否掉后没有 26-only API 了）。保留它是因为这是自用原型、不分发，低 target 只会引入"在旧系统上没测过"的不确定性；且以后要用 macOS 26 的新 API 时不必包 `#available` |
| 完成度 | demo 级 | 见 §1 |
| 仓库位置 | `herda/`，独立 git | 该目录位于 herdr 工作副本内，但**不进 herdr 的 git 历史**。herdr 侧通过本地 `.git/info/exclude` 忽略，不修改仓库内的 `.gitignore` |

关于最后一项：本机认证账号 `jeasonstudio` 不在 `.github/MAINTAINERS`（`ogulcancelik` / `akbash-bot` / `kangal-bot`）中，remote 为 canonical `herdrdev/herdr`。按仓库自身规则属 external contributor，因此本项目保持为独立仓库，不向 herdr 提交或推送。

**方案 A 的天花板（明确接受）：** pane 分隔线、tab bar、herdr 自身的 modal 仍由 ratatui 以字符绘制；无法对单个 pane 做原生滚动条或右键菜单。但 grid 由客户端用 Core Text 绘制，字体渲染质量与平滑滚动等原生优势仍然获得。若原型验证想法成立，可逐步把终端区拆为 per-pane 原生 view。

## 4. 架构：进程模型与隔离

```
macOS App (单窗口, Swift)
    │
    ├── API socket ──────┐
    └── client socket ───┤
                         ▼
              herdr server (内嵌 binary, headless)
                         │
                    PTY × N (claude / shell / ...)
```

App 是 server 的父进程。server 以 headless 模式运行（`herdr server`，见 `src/cli.rs:82`），不带任何 TUI 客户端。

### 隔离

开发机上已有一个运行中的 herdr session（约 22 个 pane）。原型的 server 必须完全隔离。给子进程设置：

```
HERDR_SOCKET_PATH = <Support>/runtime/herdr.sock   → API socket；client socket 由它派生
XDG_CONFIG_HOME   = <Support>/runtime/config       → config_dir() = <Support>/runtime/config/herdr
XDG_STATE_HOME    = <Support>/runtime/state
```

其中 `<Support>` = `~/Library/Application Support/app.herda`。依据：`src/config/io.rs:29` 的 `config_dir()`、`src/server/socket_paths.rs` 的 socket 解析。

**用 `HERDR_SOCKET_PATH` 而非 `HERDR_SESSION`。** 前者优先级最高，且 client socket 由它按「在 `.sock` 前插入 `-client`」的规则派生（`herdr.sock` → `herdr-client.sock`），两个路径因此完全确定，无需推断具名 session 的路径规则。该派生规则已由探针实证。注意两者不能混用：`client_socket_path()` 在检测到显式 session 时会走 session 分支并忽略 `HERDR_SOCKET_PATH`。

**必须先清除继承的所有 `HERDR_*` 环境变量。** 这个 app 很可能本身就是从一个 herdr 会话里启动的（直接启动，或经由从 herdr 里启动的 Xcode），继承下来的 `HERDR_SOCKET_PATH` / `HERDR_CLIENT_SOCKET_PATH` / `HERDR_SESSION` 会把子进程指向开发者的真实 server。herdr 自己的 `CLAUDE.md` 也要求测试时用 `env -u HERDR_SOCKET_PATH -u HERDR_CLIENT_SOCKET_PATH` 清除它们。

App 启动前在 `<Support>/runtime/config/herdr/config.toml` 写入：

```toml
[ui]
sidebar_collapsed_mode = "hidden"

[keys]
toggle_sidebar = "ctrl+alt+f20"
```

`Hidden` 模式使 `sidebar_w = 0`，完全不占宽度（`src/ui.rs:229`）。

把 `toggle_sidebar` 显式绑到 `ctrl+alt+f20` 有三个好处：

1. 用户不可能误触把 sidebar 弄回来，因此**不需要在输入层做拦截**。
2. 键位在自己控制下，不受上游默认值变动影响。
3. **避开 `Char` 的 bincode 编码。** 默认的 `prefix+b` 要求先发 `ctrl+b`，即 `ClientKeyCode::Char('b')`；而 `char` 在 bincode 中的表示未经验证。改用带 modifier 的功能键后，只需 `F(u8)` 变体（变体序号 16，payload 为单字节），M1 无需实现 `Char` 编码。

语法依据：`parse_key_combo`（`src/config/keybinds.rs:1201`）按 `+` 分割并识别 modifier token；`keybinds.rs:1259` 的 `s.starts_with('f') => s[1..].parse::<u8>()` 将 `f20` 解析为 `KeyCode::F(20)`。`modifiers: u8` 直接经 `KeyModifiers::from_bits_truncate` 还原（`src/protocol/wire.rs:305`），故 `ctrl+alt` = `2 | 4` = `6`（crossterm 0.29 位定义：SHIFT=1、CONTROL=2、ALT=4、SUPER=8）。

### 启动序列（顺序敏感）

1. 定位 binary — 依次尝试 bundle `Resources/herdr` → `PATH` 中的 `herdr` → 硬编码回落 `~/.local/bin/herdr`。原型阶段三者均接受；取到后记录实际路径以便诊断
2. 写 config.toml，spawn `herdr server`，带上隔离环境变量，stderr 重定向到 pipe
3. 轮询等两个 socket 文件出现（超时 10s）
4. `ApiClient` 连 API socket，`ping` 确认存活
5. `ClientProtocolConn` 连 client socket，发 `Hello{App, SemanticFrame, cols, rows}`；`cols`/`rows` 由终端区视图的像素尺寸除以 cell 尺寸得出（cell 尺寸取自所选等宽字体的 advance width 与 line height）
6. 收 `Welcome`，**校验 `version == 19`，不等则报错退出**，不尝试兼容
7. 发一次 `ctrl+alt+f20`（§4 中自己绑定的键位）隐藏 sidebar
8. 开始收帧渲染；`ApiClient` 订阅事件，侧边栏上线

第 7 步是方案 A 唯一的 hack。原因：`sidebar_collapsed` 是运行时状态（`src/app/state.rs:1873` 默认 `false`），config 无对应初始值，persist 也不保存它，API 亦无相应方法。因此只能通过按键 toggle 一次。

注意这意味着 **M1 需要 `InputEvents` 的 `Key` 编码能力**（用于发出这一次按键），即使 M1 不处理用户输入。M2 只是把用户事件接进这条已经打通的路径。

### 关闭

调 `server.stop` API；超时未退则 SIGTERM。demo 级不做崩溃恢复——server 死亡则在窗口显示错误并要求重启 app。

### 版本 pin

`PROTOCOL_VERSION = 19` 作为常量写死在 Swift 侧，与 bundle 内的 binary 一起版本化。

## 5. 组件划分

工程由 `xcodegen` 从 `project.yml` 生成（本机已装），产出标准 `.xcodeproj`。三个 target：

```
herda/
  project.yml                      # xcodegen 输入，.xcodeproj 由它生成
  Sources/
    HerdaKit/                      # 静态库：全部逻辑
      Runtime/     HerdrRuntime · RuntimePaths
      Protocol/    Varint · ByteReader · Framing · WireTypes
                   WireEncoder · WireDecoder · ClientProtocolConn · ApiClient
      Terminal/    CharWidth · TerminalColor · TerminalGridView · InputTranslator
      Sidebar/     SidebarViewModel
      Theme/       Theme · ThemeCatalog · ChromeSurfaces
                   ChromeMetrics · CardSurface
    Herda/                         # application：仅 UI 入口
      HerdaApp.swift · ContentView.swift · SidebarView.swift
  Tests/
    HerdaKitTests/                 # 只依赖 framework，不需要 host app
  docs/
    design.md · plan-m1.md
```

**逻辑必须放在独立库而非 app target。** 若单元测试以 app 为 test host，运行测试会启动 app，连带执行启动序列并 spawn 一个真实的 herdr server——这会让测试产生副作用且变慢。独立库使 `HerdaKitTests` 无需 host app。

该库须是**静态库**而非 framework：framework 被嵌入 xctest bundle 时 codesign 会以 `bundle format unrecognized, invalid, or unsuitable` 失败（实测）。另外 xcodegen 不会为 test bundle 生成 Info.plist，需显式设 `GENERATE_INFOPLIST_FILE: YES`，否则签名步骤直接报错。

| 组件 | 职责 | 依赖 | 明确不管 |
|---|---|---|---|
| `HerdrRuntime` | spawn / 监控 / 停止 server，产出两个 socket 路径 | `Process` | 协议、渲染 |
| `WireCodec` | bincode varint + framing + 消息编解码 | 无（纯函数） | IO |
| `ClientProtocolConn` | 一条 client socket 的握手与收发循环 | `WireCodec` | 渲染、布局 |
| `TerminalGridView` | `FrameData` → Core Text 绘制 | `CharWidth` | 输入、协议 |
| `InputTranslator` | `NSEvent` → `ClientInputEvent`（M2） | `CharWidth`（鼠标坐标换算） | IO |
| `ApiClient` | NDJSON 请求 + `events.subscribe` | 无 | wire 协议 |
| `SidebarViewModel` | workspace / agent 状态与用户意图 | `ApiClient` | 终端 |

`WireCodec`、`InputTranslator`、`CharWidth` 为纯函数，承载最易出错的逻辑，也是唯一值得写单测的部分。

### 协议实现要点

**framing**：`[u32 LE length][bincode payload]`（`src/protocol/wire.rs:868`）

**bincode 2 `standard` config**：整数用 varint，小端。`u8` 与 `bool` 为单字节（不参与 varint）。

varint 规则：

| 首字节 | 含义 |
|---|---|
| `0..=250` | 该值本身 |
| `251` | 后随 u16 LE |
| `252` | 后随 u32 LE |
| `253` | 后随 u64 LE |

enum 按变体序号（varint）编码；`String` / `Vec<T>` 为 varint 长度加内容；`Option` 为 `0` / `1` tag。

需要的变体序号：

- `ClientMessage`：`Hello`=0、`Input`=1、`Resize`=3、`Detach`=4、`InputEvents`=7
- `ServerMessage`：`Welcome`=0、`Frame`=1、`ServerShutdown`=4、`Notify`=5、`Clipboard`=6、`WindowTitle`=7、`MouseCapture`=9

**未关心的 `ServerMessage` 变体整帧丢弃，不视为错误。** framing 已给出长度，跳过是安全的（server 会发 `Graphics`=3、`ReloadSoundConfig`=8、`KittyKeyboardReportAll`=10 等本原型不处理的消息）。这与 §8 "解码失败即严格报错"不矛盾——区别在于「认识该变体但解码出错」（严格失败）与「不关心该变体」（安全跳过）。

**颜色解包**（`src/protocol/wire.rs:722` 的 `color_to_u32`）：高位 tag `0x00` 为命名色（0..16）、`0x01` 为调色板索引、`0x02` 为 RGB（低 3 字节）。

**modifier**：ratatui `Modifier` 位，另有 underline style 占高 4 位（`UNDERLINE_STYLE_SHIFT = 12`，mask `0xF000`）。

**`char` 编码（已实测，M2 需要）**：bincode 2 `standard` 把 `char` 编码为 **UTF-8 字节序列，不带长度前缀**——这与 `String`（varint 长度 + UTF-8）不同，是容易写错之处。

```
'b'  (U+0062)  -> 62               Char('b')  -> 0f 62
'é'  (U+00E9)  -> c3 a9            Char('更') -> 0f e6 9b b4
'更' (U+66F4)  -> e6 9b b4         F(20)      -> 10 14
'👍' (U+1F44D) -> f0 9f 91 8d
```

对 ASCII 恰好与 u32 varint 相同（`'b'` 均为 `62`），但非 ASCII 完全不同（`'更'` 的 varint 是 `fb f4 66`）。M2 只需 ASCII 字母组合（`ctrl+c` 之类），普通文本走 `TextCommit(String)`。已确认变体序号：`Enter`=1、`Esc`=14、`Char`=15、`F`=16。

## 6. 数据流

```
渲染   server ─client socket→ ClientProtocolConn → WireCodec.decode → FrameData → TerminalGridView
输入   NSEvent → InputTranslator → ClientInputEvent → WireCodec.encode ─client socket→ server
侧边栏 server ─API socket→ ApiClient(events.subscribe) → SidebarViewModel → SidebarView
```

两条通道完全独立：渲染卡住不影响侧边栏，反之亦然。这是方案 A 顺带得到的好处——终端区是一整块，无需协调 N 条连接。

## 7. 里程碑与验收

三个里程碑递进，M1 是 gate。

### M1 — 能看到画面

内嵌 binary 与进程生命周期、隔离的 config/socket、client socket 与 wire 编解码、启动时隐藏 sidebar、`FrameData` → Core Text 渲染（宽字符、三种颜色编码、modifier、光标）。

不处理用户输入，但**需实现 `InputEvents` 的 `Key` 编码**——启动序列第 7 步要用它隐藏 sidebar。

验收：无 sidebar 残留 · 中文行不错位（`CharWidth` 对照测试通过）· 颜色与 TUI 一致 · 输出滚动流畅

### M2 — 能用

键盘 / 鼠标 → `InputEvents`（复用 M1 已打通的编码路径），IME → `TextCommit`，剪贴板，`Resize`。

验收：打字回显无感延迟 · `ctrl+b` 系列快捷键正常（含默认的 `prefix+b` 现为未绑定、按下无副作用）· 中文输入法能 commit · resize 后重排正确

注：M2 处理用户输入时才需要 `ClientKeyCode::Char`，其 bincode 表示届时必须先验证（写一小段 Rust 编码 `'b'` 观察字节）。普通文本输入优先走 `TextCommit(String)`，`Char` 只用于带 modifier 的字母组合（如 `ctrl+c`）。

### M3 — 原生侧边栏

`ApiClient` + `events.subscribe`，SwiftUI 侧边栏显示 workspace / agent 与 `agent_status`，点击切换焦点（`workspace.focus` / `pane.focus`）。

验收：所有 workspace / agent 可见 · `agent_status` 实时变化 · 点击能切焦点

M1 + M2 + M3 合起来构成"最小日常可用闭环"。M1 不过关则后两个不做。

### M4 — macOS 26 窗口 chrome

sidebar 与窗口底同层同色、贴左边缘、铺满高度；只有终端是一张圆角卡片浮在这一面上。间距（8pt 网格）取代原来 sidebar 与终端之间那条 hairline。deployment target 提到 macOS 26。表面保留 theme 实色，不用 Liquid Glass。

中途做过双卡片（sidebar 与终端各一张），观感把窗口切得太碎，退回单卡片——见 `plan-m4.md` 的「后续修订」。

顺带修掉两个既有缺陷：

- 卡片顶边的净空原先是 28pt，沿用 macOS 15 的 titlebar 高度，而 macOS 26 的拖动带实测 **32pt**——终端顶部 4pt 的点击一直被吞成拖窗口。
- 分隔线与卡片描边原先一律取 `hairline`（相对 `panelBackground` 派生），而它与 `windowBackground` 在亮色主题下收敛到差 0–6——描边与 sidebar 分隔线在那些主题下看不见。改为相对所在面派生。

验收：终端卡片圆角、阴影、描边可见 · 终端顶部点击不触发窗口拖动（由拖动带高度的实测断言保证，不靠 GUI 点击） · 18 个主题在真实绘制下描边独立可辨，`terminal` 主题面色差为零、由描边托起

设计见 `superpowers/specs/2026-08-11-macos26-chrome-design.md`（该文记录的是双卡片方案，顶部有修订说明），实现见 `plan-m4.md`。

## 8. 错误处理

原则：**demo 级 = 不恢复，但必须可诊断。** 不做自动重连、不做自动重启。所有失败变成明确的错误信息加日志。静默恢复会掩盖协议不一致这类真问题。

| 失败 | 处理 |
|---|---|
| binary 找不到 / server 启动失败 | 窗口显示错误 + server stderr |
| socket 等待超时 | 报超时，附期望的 socket 路径 |
| `Welcome.version != 19` | 报"binary 与 app 版本不匹配"并退出 |
| `Welcome.error` 非空 | 显示 server 给出的原因 |
| `ServerShutdown` / socket EOF | 窗口进入"已断开"态，显示 reason |
| bincode 解码失败 | 见下 |

解码失败是手写解码器唯一的致命风险，需特殊对待。照搬 herdr 自身的严格策略（`src/protocol/wire.rs:920` 的 `consumed != claimed_len` 检查）：**严格校验消费字节数，任何不一致立即失败并 dump 出错 payload 的十六进制，绝不"尽力解析"。** 静默错位会表现为"偶尔花屏"，是最难排查的 bug。同理，`cells.count != width * height` 的帧直接拒绝并记录。

## 9. 测试策略

只测三个纯函数组件。

| 测试 | 内容 |
|---|---|
| `WireCodecTests` | varint 往返（边界 250 / 251 / 65535 / 65536）、framing 往返、`Hello` 字节 golden test、`FrameData` 解码 fixture |
| `CharWidthTests` | CJK / emoji / 组合字符 / Variation Selector 宽度；真实一屏的列位置对照 |
| `InputTranslatorTests` | modifier 位映射、`prefix+b` 被拦截、IME 走 `TextCommit` |

不测渲染像素、UI 布局、进程管理——demo 级不值得，靠手动跑。

**fixture 生成**：扩展 `.local/probe` 增加 dump 模式，把真实的 `Hello` 字节与 `Frame` payload 存为文件，直接作为 Swift 测试的 golden fixture。这样 Swift 解码器与 Rust 实现逐字节对齐，而非照结构定义猜测。

## 10. 明确不做

- 签名、公证、自动更新、分发
- 崩溃恢复、自动重连
- kitty graphics / 图片显示。注意区分：`FrameData::graphics` 字段**必须照常解码**（否则字节流错位），只是不渲染其内容
- 远程 / SSH（herdr 有 `src/remote/`，原型不涉及）
- 多窗口、多 tab
- per-pane 原生交互（滚动条、右键菜单）——方案 A 的已知天花板
- 原生 split 布局

## 11. 已知风险

| 风险 | 说明 | 缓解 |
|---|---|---|
| ~~`CharWidth` 与 ghostty-vt 不一致~~ **（M1 已排除）** | 原判断为最大技术风险 | 系统 `wcwidth` 加 emoji 预判断的组合与 ghostty-vt 一致，含 CJK、emoji、框线字符，经真实内容人眼确认无错位 |
| ~~渲染性能不足~~ **（M1 已排除）** | 担心逐 cell 绘制过慢 | `seq 1 400000` 快速滚动无卡顿，不需要合并 run |
| 手写 bincode 解码器静默错位 | 结构定义抄错会产生难查的花屏 | 严格字节数校验 + golden fixture 来自真实字节 |
| 协议版本 bump | herdr 演进会改 `PROTOCOL_VERSION` | 自带 runtime 使两者一起版本化；启动时严格校验并明确报错 |
| 方案 A 原生感不足 | 分隔线与 modal 仍为字符绘制 | 已知并接受；验证成立后可走向 per-pane 原生 view |
| ~~sidebar toggle 无效~~ **（M1 已解决）** | 根因是 `Mode::Onboarding`：首次运行时 server 停在引导模式，`input/mod.rs:99` 会把每个按键交给 `handle_onboarding_key`，**在 keybinding 匹配之前就吞掉**，所以 toggle 从不触发；同时引导浮层遮住终端，而 M1 没有输入层、用户也无法关掉它 | config 顶层加 `onboarding = false`（依据 `config/model.rs:1741`）。必须置于所有 `[section]` 之前，否则会被当成该 section 的键而静默失效——已有测试守护此顺序 |
| ~~`Char` 的 bincode 表示未验证~~ **（已实测确认）** | 曾是 M2 的前置未知 | `char` = UTF-8 字节、无长度前缀（详见 §5）。M2 只需 ASCII 字母组合，文本输入走 `TextCommit` |
