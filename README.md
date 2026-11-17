# dsh-screenshot

给 [DeepSeek Harness](https://github.com/deepseek-ai)（DSH）桌面端加一个**像微信 / QQ 那样的截图按钮**：点一下，整个屏幕冻结，直接在真实屏幕上拖框选区；松手后可以在原地调整选框、用画笔涂鸦圈重点，确认后这张图就直接作为图片附件进入当前对话草稿。

> 输入框工具行：`＋` · `完全权限` · 😊 · **📷** · `＋ 技能`，截图按钮就在表情按钮右边。

## 效果

- 截的是**物理像素**：进程先做 DPI 感知，125% / 150% 缩放下输出也不会被缩放糊掉
- 选区可以继续调：8 个控制点缩放、框内拖动整体移动、框外重新拉
- 就地涂鸦：画笔 / 矩形 / 箭头，红黄蓝三色，`Ctrl+Z` 撤销
- 浮动工具条贴在选区右下角（放不下会自动翻到上方），拖动过程中不挡视线
- 可选「截图时隐藏 DSH 窗口」，截到的是桌面而不是自己
- 全程本机回环，临时图片用完即删

## 安装

需要 DSH 桌面端 + Windows 10/11（原生编辑器依赖 PowerShell 5.1 与 .NET Framework 自带的 WinForms / System.Drawing）。

```bash
git clone https://github.com/chguo-3/dsh-screenshot.git
```

然后在 DSH 里用插件管理器安装这个目录（bundle 入口是本目录，安装类型为本地目录 / `install_bundle`），装完刷新一次窗口（`Ctrl+R`）即可在输入框看到相机按钮。

安装后如果按钮没出现，按顺序检查：

1. `conversation.input.left` 槽位里有没有 `screenshot` 这个 occupant
2. 打开 `http://127.0.0.1:<DSH 端口>/dsh-screenshot/diag`，应返回 `{"ok":true,...}`

## 用法

1. 点相机图标 → 屏幕冻结压暗，十字光标
2. 拖动鼠标框选（不拖动直接松手 = 整屏）
3. 松手后用浮动工具条改：`选区 / 画笔 / 矩形 / 箭头 / 取色 / 撤销 / 清空 / 取消 / 完成`
4. `Enter` 或「完成」→ 裁切 + 烧入笔迹 → 进草稿
5. `Esc` / 右键 / 关窗 → 取消，什么都不留下

快捷键：`1`–`4` 切换工具，`Ctrl+Z` 撤销，`Ctrl+C` 把当前裁切复制到剪贴板，`Esc` 取消，`Enter` 完成。

## 截图时隐藏 DSH 窗口

按钮右侧的小箭头打开菜单，勾选「截图时隐藏 DSH 窗口」后：

- 抓屏前把自己的窗口藏起来，截到的是桌面，不会把自己截进去（选择会记住）
- 抓完立刻恢复；即使脚本被强杀，下次插件启动时也会根据标记文件把窗口放回来

## 实现

渲染进程拿不到 `desktopCapturer`（DSH 桌面壳没有注册 `setDisplayMediaRequestHandler`），所以截图交给插件 Host —— 它是一个普通 Node 进程，可以直接调系统能力：

```
client.js      在 conversation.input.left 注册相机按钮，在 shell.overlay 注册失败提示
index.js       注册本机回环路由 /dsh-screenshot/*，把 selector.ps1 落成临时脚本并运行
selector.ps1   Windows 全屏编辑器：冻结整屏 → 框选 / 调选区 / 涂鸦 → 按物理像素裁切烧笔迹
```

拿到 PNG 后走 DSH 自己的草稿链路：`conversation.createDrafts(sessionId, [file])` → `inputActions.addAttachments(ids)`，被拒绝时 `releaseDraftAttachments` 回滚并提示。

路由（只接受 `Host` 头为回环地址的请求）：

| 路由 | 说明 |
| --- | --- |
| `GET /dsh-screenshot/capture` | 交互式截图，返回 `image/png`；用户取消返回 `409 {"cancelled":true}` |
| `GET /dsh-screenshot/capture?mode=full` | 整屏抓图（调试用） |
| `GET /dsh-screenshot/capture?rect=x,y,w,h` | 跳过交互直接裁切（无人值守自检用） |
| `GET /dsh-screenshot/capture?hide=1` | 抓屏时隐藏 DSH 窗口 |
| `GET /dsh-screenshot/diag` | 运行环境自检 |

## 其它平台

- **macOS**：`screencapture -i -x`（系统交互框选，没有涂鸦与浮动工具条）
- **Linux**：依次尝试 `gnome-screenshot -a` / `spectacle -r` / `maim -s` / `scrot -s`

## 已知限制

- 涂鸦、调选区、浮动工具条目前只有 Windows 原生编辑器有
- 多显示器按「整个虚拟屏幕」冻结，跨屏拖选可用
- 隐藏窗口依赖窗口标题匹配（`DeepSeek Harness`），换标题后需要改 `selector.ps1`

## 自检

```powershell
Invoke-WebRequest 'http://127.0.0.1:<端口>/dsh-screenshot/capture?mode=full' -OutFile shot.png
Invoke-WebRequest 'http://127.0.0.1:<端口>/dsh-screenshot/capture?rect=100,120,640,400' -OutFile crop.png
Invoke-WebRequest 'http://127.0.0.1:<端口>/dsh-screenshot/capture?rect=100,120,640,400&hide=1' -OutFile crop2.png
```

`selector.ps1` 另有两个调试开关：`DSH_SHOT_SELFTEST=1`（预置三笔涂鸦，验证烧录）、`DSH_SHOT_DEMO=1`（预置选区，核对工具条与控制点）。

## English

A DeepSeek Harness plugin that adds a WeChat-style screenshot button to the chat composer: the screen freezes, you drag a region right on the desktop, adjust it and annotate it with the floating toolbar, and the crop lands in the draft as an image attachment. Windows uses a native PowerShell/WinForms editor at physical pixel resolution; macOS and Linux fall back to the system selection tools.

## License

[MIT](LICENSE)
