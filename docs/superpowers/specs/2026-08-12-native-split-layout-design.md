# 原生 split 布局设计

2026-08-12。改造对象：终端区的**布局所有权** —— 从「herdr 用字符网格排布 pane，herda 照着重绘」改成「herda 用原生 view 排布 pane，herdr 只提供每个 pane 的终端」。

**本文是第二版设计。第一版已实现并被否决**，原因见下一节；它的方案与被否决理由完整保留在「第一版：切割单块 grid」一节，因为那是本文所有取舍的由来。

本文所有关于 herdr 行为的结论都来自 `herdrdev/herdr` 工作副本（`69a07fd`，binary 0.8.0，`PROTOCOL_VERSION = 19`，与 `HerdaKit.protocolVersion` 一致）的源码行号，或本机实测。凡未标注来源的判断都已被删掉。

## 第一版：切割单块 grid（已实现，已否决）

第一版让 herdr 的字符网格对布局保持权威，herda 按 `pane.layout` 返回的 rect 把单块 grid 切成 N 份，用 `pane_borders = false / pane_gaps = true` 让 herdr 不画边框并留出一格空隙。

它跑通了，测试 387 全过。否决它的不是缺陷，是**这些后果都是那个前提的必然推论，逐条修都修不掉**：

- **间距被量化成一格。** 13pt 字号下是 8pt，改字号就改布局。布局是窗口尺度的事，字号是内容尺度的事，两者被绑在一起。
- **圆角必须从那一格里挤。** 卡片内容必须恰好等于 `rect × cellSize`，于是 8pt 的格要同时供养圆角内缩（`0.293r` 规则）和可见间距，最后妥协成 2pt 内缩 / 6pt 圆角 / 4pt 间距。这三个数没有一个落在既有的 8pt 网格上。
- **跨界内容只能靠启发式发现。** herdr 的 modal 画在整块 grid 上会跨越 pane 边界，切割会把它切开并丢掉落在间隙格的内容。第一版的解法是 `GapProbe`：检查间隙格是否空白，非空就**放弃整个卡片网格**退回整块渲染。也就是靠猜 herdr 的意图来决定用哪种视觉模式。
- **PTY 尺寸由 herdr 的 rect 决定**，per-pane 鼠标坐标算错（已知缺陷，未修），滚动条要从轮询的 `pane.scroll` 反推。
- **拖分隔线是往返请求且按格量化。**

最后那个「三个 pane 显示成一张大卡片」的 bug 值得留在记录里：根因是 `isWholeGridFallback` 只在帧到达时重算，而 herdr 对相同内容做帧去重，于是布局到达后可能长时间没有下一帧，标志停在初始值。它被修好了（布局变化时用保留的最后一帧重跑路由），但**修法是让一个启发式跑得更勤**。那个启发式本身才是缺陷。

同期还有三次「修复」建立在错误假设上，完全没有解决问题：以为多余的布局事件来自别的 workspace/tab 而加了两层过滤，实测 `tab_count=1`，过滤不可能挡住任何东西；真正的成因是 `run.sh` 用 `pkill -9` 保留 server，而 SIGKILL 从不发 Detach，累积的僵死 render target 让 `terminal_area` 反复被覆写（~10 事件/秒 vs 全新 server 的 1 次）。这条已记进 `Scripts/run.sh` 的注释。

## 第一性原理

每个 pane 跨越 herda↔herdr 边界的，最小只有三样：**尺寸出去、输入出去、单元格网格进来**。

「pane 怎么排布」不在其中。那是窗口布局，属于窗口。间距、分隔线、圆角、焦点环、滚动条同理 —— 全是原生 chrome。

herdr 本质是 **PTY + 终端模拟 + 会话持久化服务**。第一版把它当成了 UI 服务，于是必须把它的 UI 重绘一遍。本版不用它的 UI。

## 方案：per-pane `ControlTerminal` 连接（选定）

```
├── API socket (JSON)      — 侧边栏、事件、pane 生命周期、输入
└── pane socket × N (bincode) — Hello{TerminalAttach} → ControlTerminal{paneId} → Resize → 帧流
                              每条连接只有一个 pane、一个 TerminalGridView
   app 渲染连接 × 0        — 删除
```

**app 渲染连接整个消失。** `TerminalSession` 现在的整格客户端形态、`FrameSlice`、`GapProbe`、`PaneFrameRouter`、`isWholeGridFallback` 全部删除。

### 已验证的协议事实

这几条是本方案的地基，全部有源码行号或实测支持。

**一｜每条连接按自己声明的尺寸独立渲染。** `headless.rs:4063` 的渲染循环里 `let area = Rect::new(0, 0, cols, rows)`，`(cols, rows)` 逐客户端取自该连接自己的 `terminal_size`；`TerminalAttach` / `TerminalObserve` 分支走 `render_terminal_virtual(runtime, area)`（`render_stream.rs:368`）—— **单个 terminal runtime，无任何 chrome**，出来的 `FrameData` 与 App 分支同一个构造函数，herda 的 `WireDecoder` 和 `TerminalGridView` 原封不动复用。

实测（herda 自己的隔离 server，三 pane 会话，herda app 客户端同时持有 116×41）：

| observe 目标 | 请求尺寸 | 实测 ANSI 寻址范围 |
|---|---|---|
| `w1:p1` | 40×10 | row 1–10, col 1–40 |
| `w1:p2` | 100×30 | row 1–30, col 1–100 |

命令 `herdr terminal session observe <pane> --cols N --rows N`，输出是每帧一个 JSON 对象带 base64 ANSI，解码后统计 CUP（`ESC [ r ; c H`）的极值。三个 render target 同时存在、互不干扰。

**二｜`ControlTerminal` 连接的 `Resize` 直接 resize 那个 pane 的 PTY。** `ServerEvent::ClientResize`（`headless.rs:2961`）的 `TerminalAttach` 分支更新自己的 `terminal_size` / `cell_size` 后 `runtime.resize(rows, cols, cell_width_px, cell_height_px)`（`:2992`），然后 **`return true`** —— 在 `resize_shared_runtime_to_effective_size()` 之前返回，完全不碰共享网格。

`MIN_COLS = 80 / MIN_ROWS = 24`（`headless.rs:258`）只作用于 `effective_size`，**不约束 attach 连接**：上面实测的 40×10 生效即是证据，pane 可以窄于 80 列。

**三｜attach 会把该 terminal 锁出 layout 的 resize 范围。** `attach_terminal_client` 插入 `direct_attach_resize_locks`（`headless.rs:2660`），客户端移除时清除（`:1504`），而 `ui/panes.rs` 的四处 resize（`:189`、`:206`、`:250`、`:283`）全部以 `!contains(terminal_id)` 为前提。

所以 herda 持有某 pane 的控制连接后，**herdr 的 layout 引擎永远不会再 resize 那个 PTY**，即使有别的 app 客户端成为 foreground。

**四｜没有 app 客户端时 herdr 根本不排布 pane。** `resize_shared_runtime_to_effective_size_with_pending_agent_resumes` 在 `foreground_client_id.is_none()` 时直接 return（`headless.rs:1037`）。而 `is_full_app_client()` = `mode == App && !pending_terminal_attach`（`clients.rs:176`），`pending_terminal_attach` 由 `Hello` 的 `launch_mode == TerminalAttach` 置位（`client_transport.rs:566`），`promote_latest_remaining_client` 只从 `latest_app_client` 里选。herda 全部连接都是 attach 形态 ⟹ 无 foreground ⟹ 无排布。

**五｜`pane.send_keys` 是 mode-aware 的、按 pane 寻址的输入通道。** `handle_pane_send_keys`（`app/api/panes.rs:1590`）→ `encode_api_keys(runtime, &params.keys)`（`app/api_helpers.rs:37`）→ **`runtime.encode_terminal_key(...)`** —— 用那个终端**自己的**模式状态编码，然后 `runtime.try_send_bytes`。参数是 `{pane_id, keys: [String]}`；`pane.send_input` 是 `{pane_id, text, keys}`，文本与按键一次发。

**这条推翻了第一版否决 per-pane 连接的唯一理由。** 第一版写的是「必须在 Swift 里重写 `src/input/encode.rs` 的 1185 行」—— 不必，herdr 按 pane 替我们编码。application cursor mode、bracketed paste 这些无法从客户端观测的终端状态，全部留在正确的一侧（`pane.send_text` 经 `encode_api_text` 也是 bracketed-paste 感知的，`api_helpers.rs:25`）。

**但它的按键词表有洞。** `parse_api_key` → `config::parse_key_combo`（`config/keybinds.rs:1201`），词表是：`space` / `enter`|`return` / `esc`|`escape` / `tab` / `shift+tab`→BackTab / `backspace`|`bs` / `left` `right` `up` `down` / 一批标点名 / 单字符 / `f<N>`；修饰符是 `ctrl`|`control` / `shift` / `alt`|`option`|`meta` / `cmd`|`command`|`super` / `hyper`（`:1151`）。

实测（对未聚焦 pane 发送，成功无输出、失败回 `invalid_key`）：

| 键名 | 结果 |
|---|---|
| `f5` `backspace` `shift+tab` `ctrl+a` `alt+b` | 接受 |
| `home` `end` `pageup` `pagedown` `delete` `insert` | **全部 `unsupported key`**（另试 `page_up` / `pgup` / `del` 同样失败）|

`keybinds.rs` 全文搜这六个名字零命中 —— 不是拼法问题，是词表里没有。而 `KeyMap.specialKey` 把它们全映射了（keyCode 115/119/116/121/117/…）。**六个终端必需的键无法经 `pane.send_keys` 表达。**

解法分两路，都不需要猜终端模式：

- **PageUp / PageDown 走 `AttachScroll`（变体 6）。** 它的 `AttachScrollSource::PageKey { input: Vec<u8> }`（`wire.rs:400`）注释写着「child application owns page keys 时要转发的原始键字节」—— 这是为这件事专门造的路径，由 server 决定是滚 host scrollback 还是转发给子应用。比原始字节更对。
- **Home / End / Delete / Insert 走该 pane 连接的原始 `Input`。** Delete=`ESC[3~`、Insert=`ESC[2~` 与终端模式无关。Home / End 有 `ESC[H`/`ESC[F`（normal）与 `ESCOH`/`ESCOF`（application cursor）两形，而客户端观测不到模式 —— 发 CSI 形，并在计划里对 vim / less / nano / zsh 行编辑实测。

彻底修好只需 herdr 在 `parse_key_combo` 里加这六个名字（六行 match arm）。本方案不假定能改 herdr。

**六｜pane id 可作为 attach target。** `resolve_terminal_target_id_string`（`headless.rs:1666`）→ `app.resolve_terminal_target`（`app/terminal_targets.rs:33`），herdr 自己的测试 `app/mod.rs:4191` 断言 pane id 可解析。变体编号来自源码自带的 tag 测试（`wire.rs:1060` 起）：`Hello=0` / `Input=1` / `ClipboardImage=2` / `Resize=3` / `Detach=4` / `AttachTerminal=5` / `AttachScroll=6` / `InputEvents=7` / `ObserveTerminal=8` / `ControlTerminal=9`。`ClientLaunchMode` 是 `App=0` / `TerminalAttach=1`（`wire.rs:57`）。

**七｜`pane.split` 返回新 pane 的完整信息。** `handle_pane_split` 以 `encode_success(id, ResponseResult::PaneInfo { pane })` 结束（`app/api/panes.rs:125`），参数含 `target_pane_id` / `direction` / `ratio` / `cwd` / `focus` / `env`（`api/schema/panes.rs:12`）。herda 由此拿到 `pane_id` 与 `terminal_id` 去开连接。

## 硬约束

**一｜绝不在 pane 连接上发 `InputEvents`。** `ServerEvent::ClientInputEvents` **没有**对 `TerminalAttach` 早退（只拒绝 `TerminalObserve`，`headless.rs:2893`），会落到 `handle_client_input_events` → `promote_client_to_foreground(client_id)`，而该函数**没有任何 guard**（`headless.rs:1460`），会把 attach 连接提为 foreground。随后 `sync_foreground_client_state` 令 `effective_size = 那一个 pane 的尺寸`（`:1124`），`resize_shared_runtime_to_effective_size_before_input` 把**所有 pane 重排进单个 pane 的尺寸里**。

这是本方案最容易踩的坑，而且症状是全局的（所有 pane 一起变形），很难回溯到某一次按键。

输入因此分三条路，**没有一条用 `InputEvents`**：

| 输入 | 通道 |
|---|---|
| 文本（含输入法提交、粘贴） | API `pane.send_text` |
| 词表内的键与组合键 | API `pane.send_keys` |
| Home / End / Delete / Insert | pane 连接的原始 `Input`（CSI 字节）|
| PageUp / PageDown、滚轮 | pane 连接的 `AttachScroll` |
| 鼠标（开关打开时） | pane 连接的原始 `Input`（SGR 1006）|

**二｜必须用 `ControlTerminal`，不能用 `ObserveTerminal`。** observe 只更新自己的渲染区、**不 resize PTY**（`headless.rs:2997` 起的分支），于是 PTY 尺寸与卡片尺寸永久不一致、内容被裁切。每个 pane 都需要自己的 PTY 尺寸，只有 control 提供。

代价是 `ControlTerminal` 占据该 terminal 的**独占可写 owner 槽**（`terminal_attach_owners`），shell 里再 `herdr terminal attach` 需要 `--takeover`。

**三｜握手顺序固定。** `client_is_pending_terminal_mode` 要求 `pending_terminal_attach && mode == App`（`headless.rs:2672`），即必须 `Hello { launch_mode: TerminalAttach }` 之后再发 `ControlTerminal`。顺序错了 server 回 `ServerShutdown` 并踢掉连接。

**四｜cols/rows 由 view 尺寸和字体推出，不能反过来。** `cols = floor(width / cellSize.width)`、`rows = floor(height / cellSize.height)`，`cellSize` 来自 `TerminalFont`（本机 MapleMono-NF-CN 13pt → 8.0 × 17.0）。这是 CLAUDE.md「cell 度量来自字体自己的表，绝不硬编码」的直接应用。余下的不足一格的边缘由卡片内边距吸收 —— 这是第一版做不到的事：那里整块 grid 的余量会累积。

**五｜`zoomed` 由 herda 自己表达。** 第一版硬约束六（snapshot 的 `panes[]` 在 zoom 时仍报告未 zoom 的 rect）**不再适用** —— herda 不读 herdr 的 rect。zoom 是 herda `PaneTree` 上的本地状态：只显示焦点 pane 铺满、其余连接保持存活但不渲染（PTY 尺寸是否随之改变见「待定项」）。

## 拓扑归 herdr，几何归 herda

herdr 拥有**哪些 pane 存在**：PTY 生命周期、会话持久化、agent 探测、`herdr pane read` 互操作。herda 拥有**它们在哪**。

- 建 pane：herda 调 `pane.split`（拿到新 pane 信息）→ 插入自己的 `PaneTree`
- 删 pane：`pane.close`，或收到 `pane_exited` / `pane_closed` 事件 → 从树上摘除
- 几何：完全本地，不发任何请求，不读 `pane.layout`

**两边的 rect 会故意不一致**，这是无害的，因为没有任何东西渲染 herdr 的 rect。加上已验证事实三（attach 锁出 resize），herdr 的 layout 引擎也不会试图纠正它。

`layout.set_split_ratio` / `pane.resize` / `pane.layout` / `layout_updated` **本方案全部不用**。

## 失去的能力（精确列举）

**一｜herdr 的键绑定与 TUI modal 在 herda 里彻底消失。** 没有 app 连接就没有 prefix key、Navigate 模式、命令面板、任何 modal。每一项都必须原生重做或明确放弃。

**这需要一份完整清单才能动手** —— `Mode` 有 20 个变体（`app/state.rs` 的 `pub enum Mode`），漏掉一个就是某个功能静默消失。第一版 spec 已经列过 API 对应关系，直接沿用：

| Mode | 对应 API |
|---|---|
| RenameWorkspace / RenameTab / RenamePane | `workspace.rename` / `tab.rename` / `pane.rename` |
| NewLinkedWorktree / OpenExistingWorktree / ConfirmRemoveWorktree | `worktree.create` / `worktree.open` + `worktree.list` / `worktree.remove` |
| Resize | 不需要 —— 几何归 herda |
| ConfirmClose | `pane.close` |
| ContextMenu / GlobalMenu | 各操作均有对应方法，改为原生菜单 |
| Navigator | `session.snapshot` + `pane.focus` |
| Settings | 写 config.toml + `server.reload_config` |
| Copy | 原生文本选择 |

**二｜鼠标转发给主动开启鼠标上报的 TUI 应用 —— 确证的缺口。**

`ServerMessage::MouseCapture`（`wire.rs:695`）是唯一告知客户端「现在该捕获鼠标」的通道，而 `stream_host_mouse_capture_mode`（`headless.rs:3665`）**跳过所有 `!is_full_app_client()` 的连接**（`:3681`），且它的值 `should_capture_host_mouse_from`（`app/state.rs:1667`）是**全局的、按焦点 pane 判定的**。API 侧则完全没有暴露终端模式的字段或方法（对 `src/api/` 全文搜 `mouse` / `bracketed` / `application_cursor` 无命中）。

所以 herda 无法知道某个 pane 的应用是否开了鼠标上报。而 attach 模式下的 `Input` 是纯字节透传（`apply_terminal_attach_input` = `runtime.try_send_bytes`，`headless.rs:403`），不做 mode-aware 重编码 —— 无条件发 SGR 序列会在没开上报的 shell 里变成字面输入（`^[[<0;10;5M`），不可接受。

**决定：不猜。** 阶段 1 不做自动鼠标转发，提供**每个 pane 一个显式开关**（菜单项 + 卡片控件，默认关）。打开时 herda 在该 pane 的连接上用 `Input` 发 SGR 1006 序列。用户在 htop / lazygit 里自己打开，行为完全可预测。

彻底修好需要 herdr 侧新增一样东西 —— 把 `MouseCapture` 也发给 attach 客户端（改 `headless.rs:3683` 的 filter），或加一个 `pane.send_mouse` API 方法。herda 不含 herdr 代码，本方案不假定能改 herdr。

**三｜kitty graphics 不发给 attach 客户端。** `frame.graphics` 的填充以 `is_app_client` 为条件（`headless.rs:4161`）。herda 目前也不渲染图形（`FrameData::graphics` 只要求解码以免错位），**无回归**。将来要做的话走 `pane.graphics.stream`（API 里已有）。

**四｜外部 TUI `herdr` 客户端接进同一 session 会显示得不对。** 它会成为 foreground 并按自己的 rect 排布，但因已验证事实三，**改不动 herda 已 attach 的那些 PTY**，于是它自己画出来的 pane 尺寸与内容不符。herda 侧不受影响。明确列为非目标。

## 得到的能力

- **滚动输入走 `AttachScroll`（变体 6）** —— 这个变体本来就是为 attach 客户端设计的，带 `column` / `row` / `lines` / `modifiers`，`handle_terminal_attach_scroll` 要求 `ClientConnectionMode::TerminalAttach`（`headless.rs:1791`），同时处理 host scrollback 和转发给子应用，且**天然按连接寻址**，不依赖焦点。

  滚动条**显示**是另一件事：帧里不带滚动偏移，thumb 位置仍需 `PaneInfo.scroll` 的三个量（`offset_from_bottom` / `max_offset_from_bottom` / `viewport_rows`，`api/schema/panes.rs:429`），继续搭现有 1.5 秒轮询的车，滚动时本地乐观更新、轮询校正。`Terminal/ScrollbarGeometry.swift` 与 `PaneInfo.scroll` 字段是第一版留下的、**在本方案里依然成立**的两件东西，保留不动。实时的 `PaneScrollChanged` 仍然不用 —— 它是 per-pane 订阅，受「订阅集一旦开始不能扩展」的限制，pane 增删时要重建连接。
- **文本选择改为原生。** herda 手里就有 cell，可以做真正的 macOS 语义：双击选词、三击选行、拖拽扩展、Cmd+C、边缘自动滚动。这比 herdr 的 TUI 选择好。
- **鼠标坐标天然正确。** 每个 pane 是独立 view，点击位置就是 pane 局部坐标。第一版那个「点击落到错误 pane」的已知缺陷不再存在。
- **拖分隔线本地即时。** 拖动只改 `PaneTree` 的 ratio，60fps 无往返；PTY resize 去抖后发。
- **删除**：`FrameSlice`、`GapProbe`、`PaneFrameRouter`、`isWholeGridFallback`、整块回退模式、`LayoutSnapshot` / `LayoutGeometry`（读 herdr rect 的部分）、以及 `RuntimePaths` 里那六个 `[ui]` 键 —— herdr 的 TUI 不再被渲染，`pane_borders` / `pane_gaps` / `pane_scrollbars` 全部失去意义。空公告 store 仍要写（没有 app 连接时它不占屏，但保留成本为零且防御未来）。

## 组件与测试

按 CLAUDE.md「易错的逻辑是纯的，测试就在那里」，高风险件全是纯值类型。

| 文件 | 职责 | 测试 |
|---|---|---|
| `Layout/PaneTree.swift` | herda 自己的分割树：二叉，节点带方向 + ratio，叶子是 pane id。操作 `split` / `close` / `setRatio` / `zoom` | 纯值类型：分裂、关闭后父节点塌缩、ratio 边界、嵌套 |
| `Layout/PaneTreeLayout.swift` | 树 + 容器 point 尺寸 + 间距度量 → `[paneId: CGRect]`，再 → 每 pane 的 `(cols, rows)` | 纯函数：1/2/3/4 pane、多层、余量吸收、最小尺寸下限 |
| `Terminal/TerminalInput.swift` | 视图输入出口的语义类型：`key` / `text` / `mouse` / `focus`。取代现在直接吐编码字节的 `onPayload` | 纯枚举，随下一行一起测 |
| `Protocol/HerdrKeyName.swift` | `WireEncoder.Key` + `Modifiers` → herdr 按键名字符串，或「词表没有、走原始字节」的判定。`parse_key_combo` 的逆 | 纯函数：词表内每个键、修饰符组合、以及六个洞键返回 fallback |
| `Protocol/TerminalKeyBytes.swift` | 六个洞键的 CSI 字节（Home/End/Delete/Insert），以及 PageUp/PageDown 交给 `AttachScroll` 的键字节 | 纯函数，golden bytes |
| `Runtime/PaneConnection.swift` | 一条 socket、一个 pane、一个 `TerminalGridView`。握手、resize 去抖、帧投递、终端消失处理 | 握手序列与 resize 去抖策略可测；socket 部分不测 |
| `Runtime/PaneSessionCoordinator.swift` | 调和树的叶子与活连接：新增开、消失关、几何变了 resize；把 `TerminalInput` 路由到 API 或原始字节 | 纯调和与路由逻辑用假连接测 |
| `Herda/SplitContainerView.swift` | 原生卡片 + 分隔线 + 拖拽 + 焦点环 | 不测，手动跑 + 离屏渲染验卡片 chrome |
| `Herda/PaneCommands.swift` | 原生菜单命令 → API 调用 | 不测 |

改动：`TerminalSession`（从整格客户端改成协调者，或直接被 `PaneSessionCoordinator` 取代）、`ApiClient`（`pane.split` / `pane.close` / `pane.focus` / `pane.send_keys` / `pane.send_text`）、`ContentView`（`terminalArea` 换成 `SplitContainerView`）。

`GlyphCache`、`CellGeometry`、`TerminalFont`、`KeyMap`、`MarkedText`、`ScrollAccumulator`、`WireDecoder` **一行不改** —— 渲染与按键识别都不受影响。

`TerminalGridView` **要改一处**：它现在的出口是 `onPayload: (([UInt8]) -> Void)?`，直接吐已编码的 `InputEvents` 字节（`:87`，产出点在 `:170`、`:182`、`:198`、`:212`、`:231`、`:815`）。那些字节在 pane 连接上会触发硬约束一的连锁反应，所以出口必须换成 `onInput: ((TerminalInput) -> Void)?` —— 由视图报告「按了什么」，由协调者决定「发到哪、怎么编码」。这是纯机械替换：`WireEncoder.key(...)` 变成 `.key(...)`，`WireEncoder.textCommit(text)` 变成 `.text(text)`，判定逻辑（`KeyMap.decide`、输入法、组字）全部不动。

## 阶段划分（粗）

阶段边界的依据：**每个阶段结束时 app 必须可用。** 由于本方案一上手就拆掉 app 连接，herdr 的键盘操作会立刻消失，所以阶段 1 必须同时补上最基本的原生命令，否则中间态是「能看不能操作」。

1. **单 pane 走通新通道。** `PaneConnection` + 握手 + resize，一个 pane 铺满终端区，删掉 app 渲染连接。验收：输入、输出、resize、滚动都对。
2. **`PaneTree` + `PaneTreeLayout` + 原生卡片网格。** 多 pane 渲染，原生间距/圆角/焦点环（这次数值不受一格约束，直接用 `ChromeMetrics` 的 8pt 网格）。
3. **原生命令与菜单。** Cmd+D / Cmd+Shift+D 分割、Cmd+W 关闭、焦点切换、zoom，全部走 API + 菜单栏。
4. **交互补齐。** 拖分隔线、原生文本选择、per-pane 鼠标转发开关。
5. **原生替换剩余 modal。** 按上表逐个来，每步可用。

真正的实施计划由 writing-plans 产出，上面只是形状。

## 待定项（计划阶段实测）

这几条不影响架构选择，但会影响实现细节，必须实测而非推断：

1. **attach 连接会收到哪些 `ServerMessage`。** 已知有帧和 `ServerShutdown`（终端消失时 reason 为 `terminal attach ended: ...`，`headless.rs:4125`）。`Notify` / `SetTitle` / `ReloadSoundConfig` 是否也发、`Handshake` 回什么尺寸，要抓一次真实字节。
2. **zoom 时非焦点 pane 的 PTY 尺寸怎么处理。** 保持原尺寸最简单，但焦点 pane 铺满后要 resize；退出 zoom 再改回去会让子应用重排两次。可能更好的做法是 zoom 期间不动任何 PTY 尺寸，只改渲染。要实测子应用的观感。
3. **Home / End 的 CSI 形在真实应用里够不够。** 词表洞已实测确认（见已验证事实五），解法已定，但 `ESC[H`/`ESC[F` 对 application cursor mode 下的 vim / less / nano / zsh 行编辑要逐个试过。若某个应用只认 `ESCOH`，需要记下来并考虑是否值得推动 herdr 补词表。
4. **输入延迟。** `pane.send_keys` 是 JSON 请求，本地 unix socket 上应远低于一帧，但要实测确认连打不掉字、不乱序（同一 socket 单流，顺序应有保证），并确认不等响应（fire-and-forget）是否安全。
5. **`herdr pane read` 等 CLI 互操作在 attach 锁定下是否照常。** 预期照常（读路径不 resize），但值得一条实测。

## 需要更正的既有记录

`docs/design.md` **已不在仓库中**（`8c314ac chore: rm old plans` 同期删除）。第一版 spec 里那节「design.md 需要更正的记录」因此悬空，本文不再引用 design.md 的任何章节编号。

如果 design.md 要恢复（`git checkout 8c314ac^ -- docs/design.md`），需要更正的至少有：§10「明确不做：原生 split 布局」（本文推翻）、§3 决策表「server 排版 + 原生外壳」（本文推翻其前提）、以及「herdr 无 channel 可 retheme 运行中的 server」这条 —— `server.reload_config` 存在（`app/api.rs:921` → `app/mod.rs:1334` → `apply_live_config`，其中有 `theme_runtime` 重建与 `refresh_effective_app_theme()`），运行中可换主题。

`docs/superpowers/plans/2026-08-12-native-split-0{1,2,3,4}-*.md` 四份计划实现的是第一版方案，随本文作废。
