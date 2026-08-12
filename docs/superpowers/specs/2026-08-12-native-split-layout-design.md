# 原生 split 布局设计

2026-08-12。改造对象：终端区的容器结构 —— 从「herdr 用字符绘制的 split」改成原生 per-pane 卡片。不改渲染引擎、不改 wire protocol、不改侧边栏。

本文所有关于 herdr 行为的结论都来自 `herdrdev/herdr` 工作副本（`69a07fd`，binary 0.8.0，`PROTOCOL_VERSION = 19`，与 `HerdaKit.protocolVersion` 一致）的源码行号，或本机实测。凡未标注来源的判断都已被删掉 —— 这个方案前两版就是死在「读了结构定义就以为知道行为」上。

## 目标

Split Right / Split Down 之后，pane 之间是原生卡片间距与描边，不是 ratatui 画的 box-drawing 字符。每个 pane 是独立的原生 view，各自有原生滚动条，焦点由卡片描边表达。

## 非目标

- **不改渲染引擎。** `TerminalGridView`、`GlyphCache`、`CellGeometry`、`TerminalFont` 一行不改。每个 pane 复用同一个 view 类，喂给它一块切出来的子帧。
- **不改 wire protocol。** 零新变体。`ObserveTerminal` / `ControlTerminal` / `AttachScroll` 全部不需要实现（理由见「被否决的方案」两节）。
- **不写 ANSI 输入编码器。** 输入继续走 `InputEvents`，编码由 server 侧的 `encode_key`（`src/input/encode.rs:14`）负责。`KeyMap`、`MarkedText`、`ScrollAccumulator` 一行不改。
- **阶段 1 不重做 herdr 的 modal。** 主动弹出的用 config 关掉，prefix key 主动按出来的退回整块渲染。原生替换分批做，见「阶段划分」。
- **不做 per-pane 独立连接。** 仍然只有一条 render 连接。

## 现状与根因

herda 握手声明 `LaunchMode.app`（`Sources/HerdaKit/Protocol/WireEncoder.swift:38`），语义是「把整个终端区给我」。server 于是把整个 workspace 的排版结果 —— split 后的所有 pane、它们之间的分隔线、tab bar、herdr 自己的 modal —— 由 ratatui 渲染成一整块字符网格，经 `ServerMessage.frame(GridFrame)` 发过来。

客户端拿到的是 `[GridCell]` 矩阵加一个 cursor（`Sources/HerdaKit/Protocol/WireTypes.swift:50`），**不知道有几个 pane、边界在哪、谁是焦点**。那条竖线对 `TerminalGridView` 来说和 `cat` 一个文件里的竖线毫无区别。

这不是缺陷，是 `docs/design.md` 三处明确接受的天花板：§3 决策表「server 排版 + 原生外壳……布局子系统工作量为零」；§3 末「方案 A 的天花板（明确接受）：pane 分隔线、tab bar、herdr 自身的 modal 仍由 ratatui 以字符绘制……若原型验证想法成立，可逐步把终端区拆为 per-pane 原生 view」；§10 明确不做列表里的「原生 split 布局」。

本文推翻的是 §10 那一条。§3 末尾预留的路径成立，但走法和当年设想的不同。

## 被否决的方案一：per-pane `ControlTerminal` 连接

每个 pane 一条 client socket，以 `launch_mode = TerminalAttach` 握手后发 `ControlTerminal { target, takeover }`，各自收自己 pane 的帧、各自发输入。

这条路技术上完全成立，且已验证到字节级：

- 变体编号来自源码自带的 tag 测试（`src/protocol/wire.rs:1060` 起）：`Hello=0` / `Input=1` / `ClipboardImage=2` / `Resize=3` / `Detach=4` / `AttachTerminal=5` / `AttachScroll=6` / `InputEvents=7` / `ObserveTerminal=8` / `ControlTerminal=9`。前四个与 herda 已实现的完全吻合。
- `ClientLaunchMode` 是 `App=0` / `TerminalAttach=1`（`src/protocol/wire.rs:57`）。必须以后者握手，否则 `client_is_pending_terminal_mode` 拒绝并回 `ServerShutdown`。
- `ControlTerminal` 与 `AttachTerminal` 最终都进 `ClientConnectionMode::TerminalAttach`（`control_terminal_client` 直接调 `attach_terminal_client`），区别只是 target 解析：前者经 `resolve_terminal_session_target` → `resolve_terminal_target_id_string`，接受 `w1:p1` 这类 pane 标识；后者要 terminal_id。
- attach 时 server 插入 `direct_attach_resize_locks` 并 `runtime.resize(rows, cols, ...)`，此后 **PTY 尺寸由客户端做主，layout 引擎不再干预该 terminal**（`src/ui/panes.rs:189` 等四处都要 `!contains(terminal_id)` 才 resize）。
- 一个 terminal 只允许一个 attach owner（`terminal_attach_owners`），`takeover: true` 可抢。

**否决原因：输入必须走 raw 字节。** attach 模式下 `ServerEvent::ClientInput`（变体 1）才会命中 `ClientConnectionMode::TerminalAttach` 分支并调 `apply_terminal_attach_input(runtime, data)` 直写 PTY；`ClientInputEvents` 只对 `TerminalObserve` 做了拒绝，attach 会继续走 `handle_client_input_events` → `events_for_app_routing`，被当成 app 客户端的按键去路由。

也就是说这条路要在 Swift 里重写 `src/input/encode.rs` —— **1185 行**，覆盖 kitty keyboard protocol（CSI u、`REPORT_EVENT_TYPES`、`REPORT_ALTERNATE_KEYS`、`REPORT_ASSOCIATED_TEXT`）、legacy xterm 的 modified special keys、application cursor mode、鼠标 SGR/X10 编码，以及一批只有踩过才知道的边界（`encode_terminal_key` 开头那段注释记着 issue #769：release 事件在非 `REPORT_EVENT_TYPES` 下不能发字节，否则 Enter/Backspace 会重复）。

附带代价还有两条：herdr 的全部 UI（tab bar、modal、prefix key）不再出现在任何帧里；`foreground_client_id` 只从 full app 客户端里选（`src/server/clients.rs:270` 起的 `latest_app_client`），没有 app 连接时 `effective_size` 退化成 `MIN_COLS × MIN_ROWS` = 80×24（`src/server/headless.rs:258`、`:1087`）。

## 被否决的方案二：app 输入连接 + N 条 `observe` 连接

保留一条 app 连接专做输入与尺寸声明（从而复用 server 侧 `encode_key`），pane 内容走 N 条 `ObserveTerminal` 只读连接。

这条路也验证过，且解决了方案一的全部问题：

- **observe 与 app 走同一条帧构造路径**：`render_targets` 把 attach/observe 客户端也纳入渲染目标（`src/server/clients.rs` 的 `render_targets`），循环里 attach/observe 分支走 `render_terminal_virtual(runtime, area)` + `FrameData::from_ratatui_buffer_with_hyperlinks`，和 App 分支同一个 `FrameData`（`src/server/headless.rs:4130` 附近）。herda 的 `WireDecoder` 与 `TerminalGridView` 可原封不动复用。
- **三种模式的 resize 各有明确分支**（`src/server/headless.rs:2961` 起）：attach 更新尺寸并 `runtime.resize`；observe 只更新 `terminal_size` + `request_repaint`，**不动 PTY**；app 更新尺寸后 `promote_client_to_foreground` + `resize_shared_runtime_to_effective_size`。
- observe 拒绝一切输入（`ClientInput` 与 `ClientInputEvents` 两个分支都对 `TerminalObserve` 返回 false），多条 observe 之间无冲突、无 takeover 问题。

**否决原因：发现 `pane_gaps` / `pane_borders` 之后它整个变成多余。** N 条连接的生命周期管理、首帧同步、每条连接的 resize 协调、以及非焦点 pane 的 cursor 抑制（observe 帧带的是该 terminal 自己的 cursor，每个 pane 都会有一个）全是白付的成本 —— 选定方案用一条已有连接就拿到了同样的结果。

记下它是因为它仍是唯一能做到「每个 pane 尺寸完全由原生 view 决定、与 herdr layout 解耦」的路。若将来要让 pane 尺寸脱离 herdr 的 layout，从这里接。

## 选定方案

用 config 关掉 herdr 自己的 pane chrome，按 `pane.layout` 返回的 rect 把单块 grid 切成 N 份。

```
├── API socket     — pane.layout 快照 + layout_updated 事件 + pane 操作
└── app 连接 × 1   — 整块 grid，现有连接代码一行不改
```

关键在于 `pane_layout_snapshot`（`src/app/api/panes.rs:1674`）返回的 rect 不是原始 layout 矩形，而是 `apply_pane_chrome(tab.layout.panes(area), pane_borders, pane_gaps)` 的结果（`:1683`）。`apply_pane_chrome`（`src/ui/panes.rs:90`）在 `multi_pane && pane_gaps && !pane_borders` 时（`:103`）对有右邻居的 pane `shrink_for_one_cell_gap(width)`、有下邻居的 shrink height，同时 `borders = Borders::NONE`（`:112`）。`shrink_for_one_cell_gap` 就是 `size - 1`（`:82`）。

于是 `pane_borders = false, pane_gaps = true` 这一组配置同时做到三件事：herdr 不画任何字符边框；pane 之间留出恰好一格空隙；rect 就是 herda 该渲染的内容区。

三轮方案的工作量对比：

| 方案 | wire 改动 | 新连接 | ANSI 编码器 |
|---|---|---|---|
| 被否决一：per-pane attach | 4 个变体 | N 条 | 1185 行 |
| 被否决二：app + observe | 1 个变体 | N 条 | 不需要 |
| **选定：切割单块 grid** | **零** | **零** | 不需要 |

## 硬约束

这几条是代码和实测推出来的，改设计时不能绕过。

**一｜`pane.layout` 的 rect 等于实际渲染区域，但这个相等只在 `pane_borders = false && pane_scrollbars = false` 下成立。** rect 是 `apply_pane_chrome` 之后的值（`src/app/api/panes.rs:1693` 取 `pane.rect`）。渲染路径接着做两步收缩：`pane_inner_rect(info.rect, info.borders)` 在 borders 为空时原样返回（`src/ui/panes.rs:48`），`stable_terminal_inner_rect(pane_inner, pane_scrollbars)` 在 `!pane_scrollbars` 时原样返回（`:34`）。两个键都关掉，这两步才都是恒等变换，`rect == inner_rect == PTY 尺寸 == 渲染区域`。

开了任何一个，rect 就不再是内容区：`pane_borders = true` 让 `apply_pane_chrome` 走 `:112` 的另一支给出 `Borders::ALL` 且**不做 shrink**（`:103` 的条件不满足），rect 紧贴、字符边框回来；`pane_scrollbars = true` 让渲染区比 rect 窄一列（`:42` 的 `width - 1`），切出来的子帧会多一列错位。三个键必须成组设置。

rect 之间那一格空隙是 herda 用来画间距和描边的位置，不是需要额外扣除的东西。

**二｜cell 宽度实测 8.0pt，与 `ChromeMetrics.cardGap` 相同。** 本机 `MapleMono-NF-CN-Regular` 13pt（`TerminalFont.preferredFamilies` 第一优先级）：`CTFontGetAdvancesForGlyphs` 给出 advance = 7.8，`cellSize.width` 取 `advance.rounded()` = 8.0；cell.height = 17.0，与 design.md 记录一致。herdr 留的一格空隙因此正好是 8pt，等于现有的 `cardGap`，卡片间距天然落在 8pt 网格上。

这条依赖字体：`cellSize.width` 是 rounded 的，advance 落在 [7.5, 8.5) 都得 8。换字体或改字号后该值会漂，间距与 rect 的对应关系要重新测，不能假定恒为 8。

**三｜所有布局操作都发 `layout_updated`，键盘操作也一样。** 生产链条是 `impl App.handle_navigate_key`（`src/app/input/navigate.rs:127`）→ `split_focused_pane_via_api`（`:568`）→ `runtime_pane_split`（`src/app/runtime_mutations.rs:140`）→ `dispatch_runtime_mutation(Method::PaneSplit)`，与 JSON API 同一个派发器，因此同样触达 `emit_layout_updated_event`（`src/app/api/panes.rs:1728`）。`runtime_layout_set_split_ratio`（`:152`）、`runtime_pane_zoom`（`:148`）、`src/app/input/modal.rs:1150` 的 `runtime_pane_resize` 同理。

同文件 `:1724` 有一条直接改 state 的 `state.split_pane(...)`，属于 `execute_navigate_action_in_context`（`:1580`），但它的两个调用者 `handle_navigate_key(state, key)`（`:1307`）和 `execute_navigate_action`（`:1568`）**都带 `#[cfg(test)]`** —— 测试专用，不是生产路径。这条排查是整个方案的地基：如果键盘操作不发事件，UI 就跟不上布局变化。

**四｜滚动信息走 snapshot，不能走 per-pane 订阅。** `PaneInfo.scroll` 是 `Option<PaneScrollInfo>`（`src/api/schema/panes.rs:429`），带 `offset_from_bottom` / `max_offset_from_bottom` / `viewport_rows`（`:434`），正好是画 thumb 需要的三个量，且出现在 `success_response.$defs.PaneInfo` 里 —— 现有的 1.5 秒轮询（`TerminalSession.swift:166`）可以直接搭车。

实时的 `PaneScrollChanged { pane_id }` 是 per-pane **订阅**（`src/api/schema/events.rs:82`，`src/api/subscriptions.rs:287`），受「订阅集一旦开始不能扩展」的限制 —— 正是 `SidebarModel.mergeStatuses` 注释里记的那个坑，pane 增删时要重建连接。所以不用它。1.5 秒对滚动条太慢，滚动时本地乐观更新、轮询校正，与拖分隔线同一个模式。

**五｜`ProductAnnouncement` 没有 config 开关。** 启动 mode 决定（`src/app/mod.rs:500`）里它紧跟 Onboarding：`if config.should_show_onboarding() { Onboarding } else if startup_product_announcement.is_some() { ProductAnnouncement }`。`load_unseen_for_current_version`（`src/product_announcements.rs:100`）只看 store 文件，没有配置项能关。herdr 升级带新公告时它会在启动时占满屏幕，而且和 Onboarding 同类 —— design.md §11 记的那个「在 keybinding 匹配之前吞掉按键」的坑。

解法确定：`load_unseen_from_path`（`:191`）在 `store.latest` 为 None 时返回 None。store 是 `state_dir()/product-announcements.json`（`:8` 的常量、`:78`），而 `state_dir()` 取 `XDG_STATE_HOME` + app 目录名（`src/config/io.rs:36`），herda 已经把它指向自己的 runtime（`RuntimePaths.swift:28`、`:112`）。启动前把该文件写成空 store 即可，和现在写 config.toml 同一类操作。

**六｜`zoomed` 时必须忽略 `panes[]` 的 rect。** snapshot 的 `zoomed` 只是把 `tab.zoomed` 透传（`src/app/api/panes.rs:1720`），而同一份快照里的 `panes` 来自 `tab.layout.panes(area)`（`:1684`）—— **不考虑 zoom**，给的仍是未 zoom 的多 pane 布局。实际渲染完全不同：`src/ui/panes.rs:179` 在 `tab.zoomed` 时只取 `tab.layout.focused()` 一个 pane，让它占据整个 `area`（`pane_inner_rect(area, borders)`）。

所以 `zoomed == true` 时 herda 必须只渲染 `focused_pane_id` 一张卡片、铺满整个终端区，忽略 `panes[]` 里的所有 rect。照着 rect 切会拿多 pane 的矩形去切一块只有单 pane 内容的 grid，画面整体错位。

（`src/ui/panes.rs:235` 还有一处 `ws.zoomed` 的 workspace 级 zoom 走同样逻辑，但 snapshot 只暴露 tab 级的那个。若 workspace 级 zoom 也可达，需要另找信号 —— 列入待实测。）

## config 变更

`RuntimePaths.configContents` 的 `[ui]` 段新增五个键。全部属于 `UiConfig`（`src/config/model.rs:809`），默认值都是 `true`：

```toml
[ui]
pane_borders = false            # :840  不画 pane 字符边框
pane_gaps = true                # :844  pane 之间留一格空隙（默认已是 true，显式写出）
pane_scrollbars = false         # :842  不画字符滚动条 —— 否则与原生滚动条并存
confirm_close = false           # :834  关掉关闭确认 modal
prompt_new_tab_name = false     # :836  关掉新 tab 命名 modal
prompt_new_workspace_name = false  # :838  默认已 false，显式写出
```

三个 pane 键各管一件事，不能只设一部分：`pane_borders = false` 与 `pane_scrollbars = false` 共同保证 **rect 等于实际渲染区域**（硬约束一），`pane_gaps = true` 保证 **pane 之间留出那一格**，也就是原生卡片间距与描边的落点（硬约束二）。少设 borders 或 scrollbars 会让切出的子帧错位；少设 gaps 只是没有间隙可用，卡片会紧贴。

`onboarding = false` 必须留在所有 `[section]` 之前 —— design.md §11 的顺序约束不变，已有测试守护。

另需在 spawn 前写 `<runtime>/state/herdr/product-announcements.json` 为空 store（硬约束五）。

`confirm_close` 的文档措辞是「Ask for confirmation before closing a workspace」，但 `close_focused_pane_via_api_requires_confirmation`（`src/app/input/navigate.rs:586`）也以 `state.mode == Mode::ConfirmClose` 作为返回值，说明 pane 关闭同样会进这个 mode。实施时要实测确认这个键是否覆盖两者。

## 数据流

**启动。** 现有序列只加两步：config 多写上面几个键、API 通道建立后请求一次 `pane.layout`。

layout 快照必须在 app 连接 hello 完成之后取，否则 rect 是按 80×24 算的、没有意义。**这个顺序现有流程天然满足**：client 注册时就有 `if !direct_attach_requested { self.foreground_client_id = Some(client_id) }` 紧跟 `sync_foreground_client_state()` + `resize_shared_runtime_to_effective_size()`（`src/server/headless.rs:2818` 起），也就是 hello 一完成 `effective_size` 就是声明的尺寸；而 herda 正是 handshake 成功后才 `attach` 并启动 API 通道（`TerminalSession.swift:84` → `:117`）。不需要额外的等待或重取。

（`promote_client_to_foreground` 的三个生产调用点都在输入或 resize 路径上 —— `:1705`、`:2720`、`:3019` —— hello 走的是上面那条直接赋值，不经过它。`direct_attach_requested` 的连接不会成为 foreground，这也是被否决方案一里 `effective_size` 退化到 80×24 的直接原因。）

**布局变化。** 收 `layout_updated` → 整份 layout 快照替换 → view 跟着变。单向数据流，没有 diff 逻辑：pane 增删只是快照变了，SwiftUI 按 paneId 复用 view。拖分隔线时拖动中只更新本地临时 ratio（不发请求），松手发 `layout.set_split_ratio`，事件回来对齐。

**不需要建递归树。** `PaneLayoutSnapshot` 是平坦的：`panes[]` 每项直接带 rect，够摆卡片；`splits[]` 每项带 `id` / `direction` / `ratio` / `rect`，够定位可拖区域并作为 `layout.set_split_ratio` 的目标。真正的递归结构只在 `layout.export` 返回的 `LayoutDescription.root`（`LayoutNode` 的 pane/split 两支）里，本方案用不到它。

**输入。** 继续走 app 连接的 `InputEvents`。唯一新增的是坐标换算：pane 卡片内的鼠标位置要加上该 pane rect 的原点还原成全局 grid 坐标，因为 herdr 用 `pane_at(col, row)`（`src/app/input/mouse.rs:1426`）命中 pane。约束是 `:78` 的 `if self.mode != Mode::Terminal { return; }` —— herdr 处于 modal 或 navigate 模式时鼠标不进 pane。

**滚动。** 滚轮走同一条路：换算后的坐标 → `pane_at` 命中（`:81`）→ `forward_pane_reported_wheel`（`:88`）。滚非焦点 pane 因此天然可用。滚动条位置见硬约束四。

**pane 生命周期。** `shutdown_terminal_stream_clients`（`src/server/headless.rs:2512`）只影响 attach/observe 客户端，本方案没有这类连接，该路径完全不涉及。herda 只从 `layout_updated` 得知 pane 消失。app 连接的 `ServerShutdown` 仍然只表示会话级断开，`TerminalSession.swift:103` 的现有语义不变。

**跨界的 modal。** herdr 的 modal 画在整块 grid 上，可能跨越 pane 边界，切割后会被 8pt 间距切开一条缝，落在间隙格上的内容会丢失。解法是一个基于帧内容的启发式：`pane_borders = false` 时间隙格本该是空白，检测到间隙格有非空内容就退回整块 grid 渲染。纯函数，可测，不需要额外 API。

## 阶段划分

阶段边界的依据是：**「关掉 modal」和「拦截快捷键 + 原生实现」不能只做一半。** 如果关掉 modal 但仍转发 prefix key，用户按下 prefix 后 herdr 进入 Navigate 模式，grid 上会画模式提示，而且鼠标不再路由到 pane（`mouse.rs:78`）。半途状态比两端都难受。

**阶段 1（本次）**：原生 split 卡片网格 + 上面那组 config + 原生滚动条 + 拖分隔线。**保留 herdr 的全部键盘操作** —— prefix key 继续转发，split/zoom/focus/resize 都由 herdr 处理，herda 从 `layout_updated` 跟随。主动弹出的 modal 已被 config 关掉；prefix key 主动按出来的 modal 走跨界启发式退回整块渲染，是可解释的行为。

**阶段 2+（逐个替换）**：每用原生实现一个 UI，就拦截对应快捷键。herdr 侧支撑完整，116 个 API 方法覆盖了所有 modal 背后的操作：

| Mode | 对应 API |
|---|---|
| RenameWorkspace / RenameTab / RenamePane | `workspace.rename` / `tab.rename` / `pane.rename` |
| NewLinkedWorktree / OpenExistingWorktree / ConfirmRemoveWorktree | `worktree.create` / `worktree.open` + `worktree.list` / `worktree.remove` |
| Resize | `layout.set_split_ratio` / `pane.resize` |
| ConfirmClose | `pane.close` + `confirm_close = false` |
| ContextMenu / GlobalMenu | 各操作均有对应方法 |
| Navigator | `session.snapshot` + `pane.focus` |
| Settings | 写 config.toml + `server.reload_config` |
| Copy | 原生文本选择 |

`Mode` 共 20 个变体（`src/app/state.rs` 的 `pub enum Mode`）。`Onboarding` 已由 config 关闭，`ProductAnnouncement` 由空 store 关闭（硬约束五），`Terminal` / `Prefix` / `Navigate` 是模式而非弹窗。`popup.close` 也有 API，popup pane 可控。

每一步都是可用状态，不存在「写到一半不能用」的窗口。

## 组件与测试

高风险件全部是纯函数，按 design.md §9 的路子，不需要 PTY、窗口或 server 就能测。

新增：

| 文件 | 职责 | 测试 |
|---|---|---|
| `Layout/LayoutSnapshot.swift` | `pane.layout` / `layout_updated` 的解码结果。平坦快照（`panes[]` + `splits[]` + `area` + `zoomed` + `focused_pane_id`），不是递归树 | 解码 fixture |
| `Layout/LayoutGeometry.swift` | pane / split rect（cell 坐标）+ cell 尺寸 + 终端区原点 → 卡片像素 frame 与分隔线可拖区 | 纯函数：1/2/3/4 pane、多层 split、**`zoomed` 退化成单卡片铺满**（硬约束六）|
| `Layout/FrameSlice.swift` | `GridFrame` + rect → 子 `GridFrame`（含 cursor 归属判定） | 纯函数，边界与宽字符占位 |
| `Layout/GapProbe.swift` | 间隙格是否有非空内容（跨界 modal 启发式） | 纯函数 |
| `Terminal/ScrollbarGeometry.swift` | `PaneScrollInfo` 三个量 → thumb 矩形 | 纯函数 |
| `Herda/PaneGridView.swift` | 按 `LayoutGeometry` 结果摆 pane 卡片 | 不测，手动跑 |

改动：`TerminalSession`（持有 layout 快照与 per-pane view）、`ApiClient`（`pane.layout` / `pane.split` / `pane.zoom` / `pane.close` / `layout.set_split_ratio` + `layout_updated` 订阅）、`ApiTypes.PaneInfo`（补 `scroll` 字段）、`RuntimePaths`（config 新键 + 空公告 store）、`ContentView`（`terminalArea` 换成 `PaneGridView`）。

坐标换算（pane 局部 → 全局 grid）也是纯函数，与 `FrameSlice` 互为逆运算，适合一起测。

## 待实测项

按 CLAUDE.md 的规矩，这三项要拿真实帧和真实服务器验证，不能靠读代码推断。建议作为实施第一步。

1. **`pane.layout` 的 rect 与实际 grid 内容是否逐格对齐。** 用 `herdr pane read` 拿地面真相，比对切出来的子帧。这是整个方案的地基，错一格就会让每个 pane 的内容平移。
2. **`pane_borders = false, pane_gaps = true` 下间隙格是否确实空白。** 决定跨界启发式成立与否。注意 `show_agent_labels_on_pane_borders`（`src/config/model.rs:846`）默认 false，但要确认关掉 borders 后它不会往别处画。
3. **`confirm_close` 是否同时覆盖 pane 与 workspace 的关闭确认。** 文档措辞与 `navigate.rs:586` 的用法不一致。
4. **workspace 级 zoom 是否可达，以及可达时如何得知。** `src/ui/panes.rs:235` 的 `ws.zoomed` 与 `:179` 的 `tab.zoomed` 是两个层级，而 snapshot 只暴露后者（硬约束六）。若前者能被触发，需要另找信号，否则那种状态下会错位。

## design.md 需要更正的记录

**§10「明确不做：原生 split 布局」** —— 本文推翻。改为记录选定方案，并保留两个被否决方案的理由。

**§3 决策表末尾关于 retheme 的记录。** design.md 写「herdr 暴露无 channel 来 retheme 运行中的 server」，`TerminalSession.swift:256` 起的注释同样基于这个判断。实际上 `server.reload_config` 存在（`src/app/api.rs:921` → `reload_config` → `src/app/mod.rs:1334` → `apply_config_from_disk(true)` → `apply_live_config`），而 `apply_live_config` 里有 `self.state.theme_runtime = theme_runtime_config(...)` + `self.refresh_effective_app_theme()`。**运行中的 server 可以换主题。**

原记录的结论「invisible in practice」仍然成立（herdr sidebar 是 hidden 的），但前提错了。而且这条能力对本方案有实际价值：`pane_borders` / `pane_gaps` / `pane_scrollbars` 都是 config 项，运行时切换要靠它；阶段 2 的原生设置面板也依赖它。

**§2 关于 `ClientLaunchMode` / `AttachTerminal` / `ObserveTerminal` / `ControlTerminal` 支持 per-pane 订阅的记录** —— 成立，且现在有了字节级的变体编号（本文「被否决的方案一」）。建议把编号记进 §5，即使当前方案不用 —— 下次考虑 per-pane 连接时不必重新查一遍。
