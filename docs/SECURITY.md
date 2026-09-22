# 安全默认约束

## 当前实现边界

- 对 MCP host 暴露的接口仍是本地 `stdio`；macOS CLI 与 `.app` app agent 之间会使用用户临时目录下的 Unix domain socket，socket 创建后会收紧为当前用户读写，且不对外监听 TCP/HTTP 端口。未设置 `OPEN_COMPUTER_USE_AGENT_SOCKET_NAMESPACE` 时继续使用历史 Socket；设置后仅以 namespace 摘要派生私有文件名，不把宿主目录或原始 namespace 写入 Socket 路径。
- 所有动作都必须显式带 `app` 参数；当前不会在后台自动扫描并控制任意 app。
- macOS 真实 app 路径依赖 `Open Computer Use.app` 已获得 `Accessibility` 与 `Screen Recording` 权限；终端里的 CLI / Node launcher 会把 `mcp`、`doctor`、`call`、`snapshot` 和 `list-apps` 转发给由 LaunchServices 启动的本地 app agent，避免把权限要求落到 iTerm / Terminal 身上。
- 这条 production 权限边界不适用于 direct `SkyClickLiveTests`：该低层 XCTest 会直接调用 CoreGraphics/SkyLight，因而必须把测试 host（例如 Terminal.app）视为独立的 test-only TCC client。`make sky-click-app-agent-acceptance` 会构建并通过 CLI/Unix socket/LaunchServices 路径调用 `Open Computer Use.app`，用于验证 production 权限仍归属于 app bundle。
- 实验性 Linux runtime 依赖已登录桌面用户的 AT-SPI2 / D-Bus session；coordinate mouse、drag、keyboard synthesis 只是 best-effort fallback，不应被视为跨 Wayland compositor 的通用后台输入授权。

## 数据处理

- 普通 app 的 screenshot 默认只在内存中编码成 PNG，并通过 MCP `image` content block 直接回传；默认不长期持久化。
- Linux runtime 的 screenshot 是 best-effort；如果 GNOME Wayland 返回黑图，bridge 会省略 image block，避免把无效截图误当成真实画面。
- fixture app 的合成状态只写到本地临时 JSON 文件，目的是支撑 deterministic smoke test；当前写入走原子替换，减少测试期间的读写竞争。
- 当前仓库不引入第三方服务，也不上传截图、AX tree 或输入内容。
- GUI acceptance 不支持 headless、SSH tty 或无登录桌面 session；这些环境不得被报告为 SkyClick production acceptance 通过。

## 授权与最小权限

- 当前只保留一层密码管理器 bundle denylist / bundle-id gate：
  - 会阻止对 1Password、Bitwarden、Dashlane、LastPass、NordPass 和 Proton Pass 做直接 `get_app_state` / action 调用。
  - 终端类 app、Chrome / Atlas 和系统组件不再属于内置阻止目标。
  - 对 bundle identifier 直传时返回 safety denial；对 app name 查询时默认不把这些密码管理器暴露成可解析目标。
- 但当前仍然没有官方闭源实现里的 session approval / 动态 app policy。
- 这意味着开源版当前的安全边界主要由：
  - 明确的 tool 调用参数
  - 内置密码管理器 denylist
  - `Open Computer Use.app` 的系统权限
  - 本地使用场景
  共同提供。
- `click_method=global` 是显式的系统级指针路径，可能移动真实鼠标、改变前台焦点或命中坐标处的其他窗口。调用参数本身不视为足够授权；macOS 和支持该模式的 Linux runtime 还要求进程环境中设置 `OPEN_COMPUTER_USE_ALLOW_GLOBAL_POINTER_FALLBACKS=1`。未设置时必须在任何可见 cursor 移动或真实输入事件之前拒绝请求。
- `click_method=app_post`、`sky_click` 与 `accessibility` 不允许静默切换到 `global`。这保证调用方选择的非侵入边界在失败时仍然成立。
- `click_method=sky_click` 是显式 macOS 私有 SPI 能力，不进入 `auto`。它不移动系统指针、不改变 WindowServer frontmost app，也不 raise 或切换目标窗口；它只向指定 PID/window 注入带 window-local metadata 的真实输入语义，并在窗口身份不匹配或私有符号缺失时 fail closed。点击后的 action-result snapshot 不执行 post-action AX refresh，避免被遮挡目标阻塞或触发恢复。第一版仅支持同一 Space 内的左键单击/双击；如果当前 macOS/Chromium 组合不接受非激活后台投递，SkyClick 必须报告失败，而不能改用会接管屏幕的 fallback。
- SkyLight ABI、raw event field 和 Chromium 接收行为都不受 Apple 公共兼容性承诺保护。系统升级后的失败不得触发静默 global fallback；应先重新验证符号和受控目标，再决定是否更新实现。
- 下一阶段应优先补：
  - session 级审批
  - 更清楚的敏感 app / 系统设置防护策略

## Planned workflow MCP boundary

`OpenComputerUseWorkflowKit` exposes the local `workflow-mcp` host. It launches
direct child MCP processes through declared tool and environment allowlists,
uses bounded process lifecycle controls, persists redacted workflow checkpoints,
and validates evidence before reporting completion. It does not prompt for app
approval, dispatch desktop input, or mutate client configuration. Existing
`open-computer-use mcp` behavior and its nine-tool surface remain compatible
and continue to be the active desktop-control security boundary.

The active execution plan for the future workflow host is
[`docs/exec-plans/active/design-inspiration-ocu-workflow.md`](./exec-plans/active/design-inspiration-ocu-workflow.md).
The host preserves these boundaries:

- Backend MCP processes receive only explicitly allowed environment-variable
  names. Configuration and logs must never contain secret values.
- Open Design uses its generated direct command and daemon configuration. It
  must not be routed through a secret-loading launcher.
- The host validates bounded motion-analysis output supplied by the active
  harness. It must not select or fall back to a model provider.
- Desktop app access requires an allowlisted bundle identifier and a
  session-scoped approval before app state or input is dispatched. Destructive
  or externally visible actions require a separate confirmation.
- Workflow requests must reject the global pointer path by default. The
  existing password-manager denylist remains in force.

## Fixture Bridge 约束

- `FixtureBridge` 只用于仓库内测试夹具，不是给第三方 app 的控制平面。
- 任何面向真实 app 的能力新增，都不应该复用这条测试专用通道。

仓库级的依赖、SBOM 和 provenance 默认能力，统一写在 `docs/SUPPLY_CHAIN_SECURITY.md`。
