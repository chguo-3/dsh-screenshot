import { spawn } from 'node:child_process'
import { existsSync } from 'node:fs'
import { readFile, rm, writeFile } from 'node:fs/promises'
import { randomUUID } from 'node:crypto'
import { tmpdir } from 'node:os'
import { dirname, join } from 'node:path'
import { fileURLToPath } from 'node:url'

/**
 * dsh-screenshot — Host half.
 *
 * 一件事，通过本机回环 HTTP 路由交给 Client half：
 *   /capture  冻结整屏 + 原地框选 / 涂鸦，直接把选好的区域回成 PNG。
 *
 * 渲染进程拿不到 desktopCapturer（桌面壳没有注册 setDisplayMediaRequestHandler），
 * 但 Host 是一个普通 Node 进程，可以直接调用操作系统的截图能力。
 */

export const name = 'dsh-screenshot'
export const inject = ['webServer']

const ROUTE = '/dsh-screenshot'
const FULL_TIMEOUT_MS = 20_000
const INTERACTIVE_TIMEOUT_MS = 180_000
const PACKAGE_DIR = dirname(fileURLToPath(import.meta.url))

/* ------------------------------------------------------------------ helpers */

function hostIsLoopback(req) {
  const host = String(req.headers.host ?? '')
  const name = host.startsWith('[') ? host.slice(0, host.indexOf(']') + 1) : host.split(':')[0]
  return name === '127.0.0.1' || name === 'localhost' || name === '[::1]' || name === '::1'
}

function sendJson(res, status, body) {
  const text = JSON.stringify(body)
  res.statusCode = status
  res.setHeader('content-type', 'application/json; charset=utf-8')
  res.setHeader('cache-control', 'no-store')
  res.setHeader('content-length', Buffer.byteLength(text))
  res.end(text)
}

function pngSize(buffer) {
  if (!Buffer.isBuffer(buffer) || buffer.length < 24) return null
  if (buffer.readUInt32BE(12) !== 0x49484452) return null
  return { width: buffer.readUInt32BE(16), height: buffer.readUInt32BE(20) }
}

/** Run a command to completion; never rejects. */
function run(command, args, { timeoutMs = FULL_TIMEOUT_MS, env = undefined } = {}) {
  return new Promise((resolve) => {
    let child
    try {
      child = spawn(command, args, {
        windowsHide: true,
        stdio: ['ignore', 'pipe', 'pipe'],
        env: env ?? process.env,
      })
    } catch (error) {
      resolve({ ok: false, error, stdout: '', stderr: '', code: null })
      return
    }
    let stdout = ''
    let stderr = ''
    let settled = false
    const finish = (result) => {
      if (settled) return
      settled = true
      clearTimeout(timer)
      resolve(result)
    }
    const timer = setTimeout(() => {
      try {
        child.kill()
      } catch {}
      finish({ ok: false, error: new Error(`${command} 超时（${timeoutMs} ms）`), stdout, stderr, code: null })
    }, timeoutMs)
    child.stdout?.on('data', (chunk) => {
      stdout += chunk
    })
    child.stderr?.on('data', (chunk) => {
      stderr += chunk
    })
    child.on('error', (error) => finish({ ok: false, error, stdout, stderr, code: null }))
    child.on('close', (code) => finish({ ok: code === 0, code, stdout, stderr }))
  })
}

class Cancelled extends Error {
  constructor() {
    super('cancelled')
    this.code = 'cancelled'
  }
}

/* ------------------------------------------------- Windows: full-screen grab */

/**
 * 抓整屏用的脚本。进程必须是 DPI-aware，否则 125%/150% 缩放下拿到的是被系统缩过的位图。
 * 输出 PNG 路径由命令行参数传入。
 */
const GRAB_SCRIPT = (out) => `
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$dpi = 'using System.Runtime.InteropServices; public static class DshShotDpi {
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}'
try { Add-Type -TypeDefinition $dpi; [void][DshShotDpi]::SetProcessDpiAwareness(2) }
catch { try { [void][DshShotDpi]::SetProcessDPIAware() } catch {} }
$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bmp = New-Object System.Drawing.Bitmap($vs.Width, $vs.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.CopyFromScreen($vs.Left, $vs.Top, 0, 0, $bmp.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
$g.Dispose()
$bmp.Save('${out.replace(/\\/g, '\\\\').replace(/'/g, "''")}', [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Output ('OK ' + $vs.Width + 'x' + $vs.Height)
`
/* -------------------------------------- Windows: frozen full-screen editor */

/**
 * 交互式截图编辑器脚本放在 selector.ps1（独立文件，便于维护与调试）。
 * 流程：可选隐藏 DSH 窗口 -> 抓整屏 -> 覆盖整个虚拟屏幕的冻结窗口 -> 拖框 -> 调选区 / 涂鸦
 *      -> 完成后按物理像素裁切并烧入笔迹，只写出一张裁好的 PNG。
 * 退出码：0 成功；2 用户取消（Esc / 右键 / 关窗）；3 参数缺失；4 运行期错误。
 * 无人值守钩子：DSH_SHOT_AUTORECT=x,y,w,h（直接裁切）与 DSH_SHOT_SELFTEST=1（带三笔涂鸦的自检）。
 */
const SELECTOR_SCRIPT_PATH = join(PACKAGE_DIR, 'selector.ps1')

/* ------------------------------------------------ 隐藏窗口的兜底恢复（win） */

/** selector.ps1 隐藏 DSH 窗口时会把句柄写进这个标记文件；脚本正常退出会自己删掉。 */
const HIDDEN_MARKER = join(tmpdir(), 'dsh-screenshot-hidden.txt')

/**
 * 如果脚本被强杀 / 超时（没走到 finally），窗口会留在隐藏状态，
 * 这里作为兜底把它放回来：进程一结束就检查标记文件。
 */
async function restoreHiddenWindows() {
  if (process.platform !== 'win32' || !existsSync(HIDDEN_MARKER)) return
  try {
    const text = await readFile(HIDDEN_MARKER, 'utf8')
    const handles = text
      .split(',')
      .map((value) => value.trim())
      .filter((value) => /^\d+$/.test(value) && value !== '0')
    if (handles.length > 0) {
      const calls = handles.map((handle) => `[void][DshRestore]::ShowWindow([System.IntPtr]${handle}, 5)`).join('\n')
      const script = `Add-Type -Namespace Dsh -Name Restore -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(System.IntPtr hWnd, int command);'\n${calls}`
      await run(
        'powershell.exe',
        ['-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-Command', script],
        { timeoutMs: 8000 },
      )
    }
    await rm(HIDDEN_MARKER, { force: true }).catch(() => {})
  } catch {
    /* 兜底失败也不该影响截图流程 */
  }
}

/* ---------------------------------------------------------------- capture */

function tempPng() {
  return join(tmpdir(), `dsh-screenshot-${randomUUID()}.png`)
}

async function grabFullScreen() {
  if (process.platform === 'win32') {
    const file = tempPng()
    try {
      const script = join(tmpdir(), `dsh-screenshot-grab-${randomUUID()}.ps1`)
      await writeFile(script, GRAB_SCRIPT(file), 'utf8')
      try {
        const result = await run('powershell.exe', [
          '-NoLogo',
          '-NoProfile',
          '-NonInteractive',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script,
        ])
        if (!result.ok || !existsSync(file)) {
          const detail = (result.stderr || result.stdout || result.error?.message || '').trim()
          throw new Error(`PowerShell 截图失败：${detail || '未知错误'}`)
        }
        const buffer = await readFile(file)
        const size = pngSize(buffer)
        return { buffer, rect: { x: 0, y: 0, w: size?.width ?? 0, h: size?.height ?? 0 }, via: 'powershell' }
      } finally {
        await rm(script, { force: true }).catch(() => {})
      }
    } finally {
      await rm(file, { force: true }).catch(() => {})
    }
  }
  return grabFullScreenPosix()
}

/** macOS / Linux 的非交互整屏抓取（测试与降级路径）。 */
async function grabFullScreenPosix() {
  const file = tempPng()
  try {
    if (process.platform === 'darwin') {
      const result = await run('screencapture', ['-x', '-t', 'png', file])
      if (!result.ok || !existsSync(file)) {
        throw new Error(`screencapture 失败：${(result.stderr || '').trim() || '系统可能拒绝了屏幕录制权限'}`)
      }
      const buffer = await readFile(file)
      const size = pngSize(buffer)
      return { buffer, rect: { x: 0, y: 0, w: size?.width ?? 0, h: size?.height ?? 0 }, via: 'screencapture' }
    }
    const tools = [
      { command: 'grim', args: () => [file] },
      { command: 'gnome-screenshot', args: () => ['-f', file] },
      { command: 'spectacle', args: () => ['-b', '-n', '-o', file] },
      { command: 'maim', args: () => [file] },
      { command: 'scrot', args: () => ['-o', file] },
      { command: 'import', args: () => ['-window', 'root', file] },
    ]
    const failures = []
    for (const tool of tools) {
      const result = await run(tool.command, tool.args())
      if (result.ok && existsSync(file)) {
        const buffer = await readFile(file)
        const size = pngSize(buffer)
        return { buffer, rect: { x: 0, y: 0, w: size?.width ?? 0, h: size?.height ?? 0 }, via: tool.command }
      }
      failures.push(`${tool.command}: ${(result.stderr || result.error?.message || '').trim() || '不存在或失败'}`)
      await rm(file, { force: true }).catch(() => {})
    }
    throw new Error(`找不到可用的截图工具：${failures.join('; ')}`)
  } finally {
    await rm(file, { force: true }).catch(() => {})
  }
}

/** Windows：整屏冻结的原生编辑器（框选 / 调选区 / 涂鸦），返回裁好并烧入笔迹的 PNG。 */
async function selectWindows(options = {}) {
  const { autoRect = null, hideApp = false, port = 0 } = options
  const file = tempPng()
  const script = join(tmpdir(), `dsh-screenshot-select-${randomUUID()}.ps1`)
  try {
    const source = await readFile(SELECTOR_SCRIPT_PATH, 'utf8')
    // PowerShell 5.1 只有在文件带 BOM 时才按 UTF-8 解析；提示语里有中文，必须补 BOM。
    await writeFile(script, `\uFEFF${source}`, 'utf8')
    const env = { ...process.env, DSH_SHOT_OUT: file, DSH_SHOT_PORT: String(port) }
    if (autoRect) env.DSH_SHOT_AUTORECT = autoRect
    if (hideApp) env.DSH_SHOT_HIDE = '1'
    const result = await run(
      'powershell.exe',
      ['-NoLogo', '-NoProfile', '-STA', '-ExecutionPolicy', 'Bypass', '-File', script],
      { timeoutMs: INTERACTIVE_TIMEOUT_MS, env },
    )
    if (result.code === 2) throw new Cancelled()
    if (!result.ok) {
      const detail = (result.stderr || result.stdout || result.error?.message || '').trim()
      if (/cancelled|canceled/i.test(detail)) throw new Cancelled()
      throw new Error(`截图失败：${detail || '未知错误'}`)
    }
    if (!existsSync(file)) throw new Cancelled()
    const buffer = await readFile(file)
    const size = pngSize(buffer)
    return { buffer, rect: { x: 0, y: 0, w: size?.width ?? 0, h: size?.height ?? 0 }, via: 'powershell-selector' }
  } finally {
    await rm(script, { force: true }).catch(() => {})
    await rm(file, { force: true }).catch(() => {})
    await restoreHiddenWindows()
  }
}

const POSIX_INTERACTIVE = [
  { command: 'screencapture', args: (file) => ['-i', '-x', '-t', 'png', file] },
  { command: 'gnome-screenshot', args: (file) => ['-a', '-f', file] },
  { command: 'spectacle', args: (file) => ['-r', '-b', '-n', '-o', file] },
  { command: 'maim', args: (file) => ['-s', file] },
  { command: 'scrot', args: (file) => ['-s', '-o', file] },
]

/** macOS / Linux：交给系统自带的交互式框选工具；返回的图本身就是选区，矩形即全图。 */
async function selectPosix() {
  const failures = []
  for (const tool of POSIX_INTERACTIVE) {
    const file = tempPng()
    try {
      const result = await run(tool.command, tool.args(file), { timeoutMs: INTERACTIVE_TIMEOUT_MS })
      if (result.ok && existsSync(file)) {
        const buffer = await readFile(file)
        const size = pngSize(buffer)
        return { buffer, rect: { x: 0, y: 0, w: size?.width ?? 0, h: size?.height ?? 0 }, via: tool.command }
      }
      if (!existsSync(file)) {
        if (result.code === 1) throw new Cancelled()
        failures.push(`${tool.command}: ${(result.stderr || result.error?.message || '').trim() || '不存在或失败'}`)
      }
    } finally {
      await rm(file, { force: true }).catch(() => {})
    }
  }
  throw new Error(
    `找不到可用的框选截图工具（尝试过 ${POSIX_INTERACTIVE.map((tool) => tool.command).join(' / ')}）：${failures.join('; ')}`,
  )
}

/* ------------------------------------------------------------------- plugin */

/** 串行化：连点时不要同时开一堆截图进程。 */
let captureQueue = Promise.resolve()
function enqueue(task) {
  const queued = captureQueue.then(task, task)
  captureQueue = queued.then(
    () => undefined,
    () => undefined,
  )
  return queued
}

export function apply(ctx, config) {
  // 上一次如果被强杀，DSH 主窗口可能还留在隐藏状态：启动时先兜底恢复。
  void restoreHiddenWindows()
  const webServer = ctx.webServer ?? ctx.get('webServer')
  if (webServer === undefined || typeof webServer.register !== 'function') {
    ctx.logger?.warn?.('[dsh-screenshot] webServer 不可用，截图接口未注册')
    return
  }

  const handleCapture = async (req, res, url) => {
    const mode = url.searchParams.get('mode')
    const rect = url.searchParams.get('rect')
    const hide = url.searchParams.get('hide') === '1'
    const port = Number(webServer.port ?? 0) || 0
    try {
      const shot = await enqueue(() => {
        if (mode === 'full') return grabFullScreen()
        if (process.platform === 'win32') return selectWindows({ autoRect: rect, hideApp: hide, port })
        return selectPosix()
      })
      res.statusCode = 200
      res.setHeader('content-type', 'image/png')
      res.setHeader('content-length', String(shot.buffer.length))
      res.setHeader('cache-control', 'no-store')
      res.setHeader('x-dsh-capture-via', shot.via)
      res.end(shot.buffer)
    } catch (error) {
      if (error instanceof Cancelled) {
        sendJson(res, 409, { cancelled: true })
        return
      }
      sendJson(res, 500, { error: error instanceof Error ? error.message : String(error) })
    }
  }

  const handler = async (req, res) => {
    if (!hostIsLoopback(req)) {
      sendJson(res, 403, { error: 'loopback only' })
      return
    }
    let url
    try {
      url = new URL(req.url ?? '/', 'http://127.0.0.1')
    } catch {
      sendJson(res, 400, { error: 'bad request' })
      return
    }
    const pathname = url.pathname

    if (pathname === `${ROUTE}/capture`) {
      await handleCapture(req, res, url)
      return
    }
    if (pathname === `${ROUTE}/diag`) {
      sendJson(res, 200, {
        ok: true,
        platform: process.platform,
        route: ROUTE,
        packageDir: PACKAGE_DIR,
        interactive: true,
        features: ['capture', 'edit', 'hide-window'],
        port: Number(webServer.port ?? 0) || 0,
        config: config ?? null,
      })
      return
    }

    sendJson(res, 404, { error: 'not found' })
  }

  ctx.effect(
    () => webServer.register({ kind: 'prefix', path: ROUTE, handler }),
    'dsh-screenshot: screen capture route',
  )
}


