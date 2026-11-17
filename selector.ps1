$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

$script:out = $env:DSH_SHOT_OUT
if (-not $script:out) { Write-Error 'DSH_SHOT_OUT missing'; exit 3 }
$script:hideApp = $env:DSH_SHOT_HIDE -eq '1'
$script:autoRect = $env:DSH_SHOT_AUTORECT
$script:selfTest = $env:DSH_SHOT_SELFTEST -eq '1'

Add-Type -AssemblyName System.Windows.Forms, System.Drawing

$dpi = 'using System.Runtime.InteropServices; public static class DshShotDpi {
  [DllImport("shcore.dll")] public static extern int SetProcessDpiAwareness(int value);
  [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
}'
try { Add-Type -TypeDefinition $dpi; [void][DshShotDpi]::SetProcessDpiAwareness(2) }
catch { try { [void][DshShotDpi]::SetProcessDPIAware() } catch {} }

$win32 = @'
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class DshShotWin {
  public delegate bool EnumProc(IntPtr hWnd, IntPtr lParam);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc callback, IntPtr lParam);
  [DllImport("user32.dll", CharSet = CharSet.Unicode)] public static extern int GetWindowText(IntPtr hWnd, StringBuilder text, int count);
  [DllImport("user32.dll")] public static extern int GetWindowTextLength(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr hWnd);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int command);
  [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hWnd);
  public static string Title(IntPtr hWnd) {
    int length = GetWindowTextLength(hWnd);
    if (length <= 0) return string.Empty;
    var builder = new StringBuilder(length + 2);
    GetWindowText(hWnd, builder, builder.Capacity);
    return builder.ToString();
  }
}
'@
Add-Type -TypeDefinition $win32

# 上一次异常退出留下的隐藏窗口：先恢复，避免应用「看不见」。
$script:marker = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), 'dsh-screenshot-hidden.txt')
function Restore-Hidden($handles) {
  foreach ($raw in $handles) {
    $value = 0L
    if ([long]::TryParse([string]$raw, [ref]$value)) {
      $ptr = New-Object System.IntPtr($value)
      if ($ptr -ne [System.IntPtr]::Zero) {
        [void][DshShotWin]::ShowWindow($ptr, 5)
        [void][DshShotWin]::SetForegroundWindow($ptr)
      }
    }
  }
}
if (Test-Path $script:marker) {
  $previous = @((Get-Content $script:marker -Raw) -split ',' | Where-Object { $_ })
  Restore-Hidden $previous
  Start-Sleep -Milliseconds 120
  Remove-Item $script:marker -Force -ErrorAction SilentlyContinue
}

$script:hidden = New-Object System.Collections.ArrayList
if ($script:hideApp) {
  $collect = [DshShotWin+EnumProc] {
    param([System.IntPtr]$handle, [System.IntPtr]$lparam)
    try {
      if ([DshShotWin]::IsWindowVisible($handle)) {
        $title = [DshShotWin]::Title($handle)
        if ($title -and $title.Contains('DeepSeek Harness')) { [void]$script:hidden.Add($handle) }
      }
    } catch {}
    return $true
  }
  [void][DshShotWin]::EnumWindows($collect, [System.IntPtr]::Zero)
  foreach ($handle in $script:hidden) { [void][DshShotWin]::ShowWindow($handle, 0) }
  if ($script:hidden.Count -gt 0) {
    Set-Content -Path $script:marker -Value (($script:hidden | ForEach-Object { $_.ToInt64() }) -join ',') -Encoding ascii
    Start-Sleep -Milliseconds 280
  }
}

# 隐藏后无论走哪条分支（无人值守 / 自检 / 正常交互 / 异常），都必须把窗口放回来。
function Restore-AppWindows {
  if ($script:hidden.Count -gt 0) {
    Restore-Hidden $script:hidden
    Remove-Item $script:marker -Force -ErrorAction SilentlyContinue
  }
}

$script:vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$script:full = New-Object System.Drawing.Bitmap($script:vs.Width, $script:vs.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$capture = [System.Drawing.Graphics]::FromImage($script:full)
$capture.CopyFromScreen($script:vs.Left, $script:vs.Top, 0, 0, $script:full.Size, [System.Drawing.CopyPixelOperation]::SourceCopy)
$capture.Dispose()

$script:rect = New-Object System.Drawing.Rectangle(0, 0, 0, 0)
$script:hasRect = $false
$script:tool = 'select'
$script:color = [System.Drawing.Color]::FromArgb(255, 59, 48)
$script:strokes = New-Object System.Collections.ArrayList
$script:mode = ''
$script:anchor = $null
$script:handle = ''
$script:base = $null
$script:cancelled = $false
$script:failure = $null

$handles = @('nw', 'n', 'ne', 'e', 'se', 's', 'sw', 'w')

function Get-RectPoints($rect) {
  $x = $rect.X
  $y = $rect.Y
  $r = $rect.X + $rect.Width
  $b = $rect.Y + $rect.Height
  $cx = $rect.X + [int]($rect.Width / 2)
  $cy = $rect.Y + [int]($rect.Height / 2)
  return @{
    nw = New-Object System.Drawing.Point($x, $y)
    n = New-Object System.Drawing.Point($cx, $y)
    ne = New-Object System.Drawing.Point($r, $y)
    e = New-Object System.Drawing.Point($r, $cy)
    se = New-Object System.Drawing.Point($r, $b)
    s = New-Object System.Drawing.Point($cx, $b)
    sw = New-Object System.Drawing.Point($x, $b)
    w = New-Object System.Drawing.Point($x, $cy)
  }
}

function Draw-Stroke($graphics, $stroke) {
  $pen = New-Object System.Drawing.Pen($stroke.Color, 3)
  $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
  $pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
  try {
    if ($stroke.Tool -eq 'pen') {
      $points = $stroke.Points
      if ($points.Count -ge 2) {
        $graphics.DrawLines($pen, [System.Drawing.Point[]]$points.ToArray())
      } elseif ($points.Count -eq 1) {
        $only = $points[0]
        $graphics.DrawLine($pen, $only.X, $only.Y, $only.X + 1, $only.Y + 1)
      }
    } elseif ($stroke.Tool -eq 'rect') {
      $a = $stroke.Points[0]
      $b = $stroke.Points[$stroke.Points.Count - 1]
      $x = [Math]::Min($a.X, $b.X)
      $y = [Math]::Min($a.Y, $b.Y)
      $w = [Math]::Abs($b.X - $a.X)
      $h = [Math]::Abs($b.Y - $a.Y)
      $graphics.DrawRectangle($pen, $x, $y, $w, $h)
    } else {
      $a = $stroke.Points[0]
      $b = $stroke.Points[$stroke.Points.Count - 1]
      $graphics.DrawLine($pen, $a, $b)
      $angle = [Math]::Atan2(($b.Y - $a.Y), ($b.X - $a.X))
      $length = 16
      $spread = 0.42
      $p1 = New-Object System.Drawing.PointF(($b.X - $length * [Math]::Cos($angle - $spread)), ($b.Y - $length * [Math]::Sin($angle - $spread)))
      $p2 = New-Object System.Drawing.PointF(($b.X - $length * [Math]::Cos($angle + $spread)), ($b.Y - $length * [Math]::Sin($angle + $spread)))
      $head = [System.Drawing.PointF[]]@(
        (New-Object System.Drawing.PointF($b.X, $b.Y)), $p1, $p2
      )
      $brush = New-Object System.Drawing.SolidBrush($stroke.Color)
      $graphics.FillPolygon($brush, $head)
      $brush.Dispose()
    }
  } finally {
    $pen.Dispose()
  }
}

function Draw-Overlay($graphics) {
  if (-not $script:hasRect) { return }
  $rect = $script:rect
  $shade = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 0, 0, 0))
  $graphics.FillRectangle($shade, 0, 0, $script:full.Width, $rect.Y)
  $graphics.FillRectangle($shade, 0, $rect.Y + $rect.Height, $script:full.Width, $script:full.Height - $rect.Y - $rect.Height)
  $graphics.FillRectangle($shade, 0, $rect.Y, $rect.X, $rect.Height)
  $graphics.FillRectangle($shade, $rect.X + $rect.Width, $rect.Y, $script:full.Width - $rect.X - $rect.Width, $rect.Height)
  $shade.Dispose()

  $state = $graphics.Save()
  $graphics.SetClip($rect)
  foreach ($stroke in $script:strokes) { Draw-Stroke $graphics $stroke }
  $graphics.Restore($state)

  $border = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 60, 130, 255), 2)
  $graphics.DrawRectangle($border, $rect.X, $rect.Y, $rect.Width, $rect.Height)
  $border.Dispose()

  if ($script:tool -eq 'select') {
    $points = Get-RectPoints $rect
    $fill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $edge = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 60, 130, 255), 1)
    foreach ($name in $handles) {
      $point = $points[$name]
      $graphics.FillRectangle($fill, ($point.X - 5), ($point.Y - 5), 10, 10)
      $graphics.DrawRectangle($edge, ($point.X - 5), ($point.Y - 5), 10, 10)
    }
    $fill.Dispose()
    $edge.Dispose()
  }

  $label = '' + $rect.Width + ' x ' + $rect.Height
  $font = New-Object System.Drawing.Font('Segoe UI', 9)
  $size = $graphics.MeasureString($label, $font)
  $bx = [Math]::Min([Math]::Max(0, $rect.X), [Math]::Max(0, $script:full.Width - $size.Width - 12))
  $by = $rect.Y - $size.Height - 10
  if ($by -lt 0) { $by = $rect.Y + 6 }
  $box = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(235, 20, 24, 32))
  $graphics.FillRectangle($box, $bx, $by, ($size.Width + 14), ($size.Height + 6))
  $text = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
  $graphics.DrawString($label, $font, $text, ($bx + 7), ($by + 3))
  $box.Dispose()
  $text.Dispose()
  $font.Dispose()
}

function New-Crop() {
  $rect = $script:rect
  $x = [Math]::Max(0, [Math]::Min($rect.X, $script:full.Width - 1))
  $y = [Math]::Max(0, [Math]::Min($rect.Y, $script:full.Height - 1))
  $w = [Math]::Max(1, [Math]::Min($rect.Width, $script:full.Width - $x))
  $h = [Math]::Max(1, [Math]::Min($rect.Height, $script:full.Height - $y))
  $bitmap = New-Object System.Drawing.Bitmap($w, $h, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
  $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
  $graphics.DrawImage($script:full, (New-Object System.Drawing.Rectangle(0, 0, $w, $h)), (New-Object System.Drawing.Rectangle($x, $y, $w, $h)), [System.Drawing.GraphicsUnit]::Pixel)
  $graphics.SetClip((New-Object System.Drawing.Rectangle(0, 0, $w, $h)))
  $graphics.TranslateTransform(-$x, -$y)
  foreach ($stroke in $script:strokes) { Draw-Stroke $graphics $stroke }
  $graphics.Dispose()
  return $bitmap
}

function Save-Result() {
  if (-not $script:hasRect) { return }
  if ($script:rect.Width -lt 4 -or $script:rect.Height -lt 4) { return }
  $bitmap = New-Crop
  try {
    $bitmap.Save($script:out, [System.Drawing.Imaging.ImageFormat]::Png)
    Write-Output ('OK ' + $bitmap.Width + 'x' + $bitmap.Height)
  } finally {
    $bitmap.Dispose()
  }
}

function Complete-Selection() {
  if (-not $script:hasRect) { return }
  try { Save-Result $script:out } catch { $script:failure = $_.Exception.Message }
  $script:form.Close()
}

$form = New-Object System.Windows.Forms.Form
$script:form = $form
$form.Text = 'dsh-screenshot'
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.Bounds = $script:vs
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.AutoScaleMode = [System.Windows.Forms.AutoScaleMode]::None
$form.KeyPreview = $true
$form.Cursor = [System.Windows.Forms.Cursors]::Cross
$form.BackColor = [System.Drawing.Color]::Black
try {
  $buffered = [System.Windows.Forms.Control].GetProperty('DoubleBuffered', [System.Reflection.BindingFlags]'Instance,NonPublic')
  $buffered.SetValue($form, $true)
} catch {}

$script:uiFont = New-Object System.Drawing.Font('Microsoft YaHei', 9)
$script:barHot = ''
$script:barButtons = @()
$script:barRect = New-Object System.Drawing.Rectangle(0, 0, 0, 0)
$script:palette = @(
  [System.Drawing.Color]::FromArgb(255, 59, 48),
  [System.Drawing.Color]::FromArgb(255, 214, 10),
  [System.Drawing.Color]::FromArgb(60, 130, 255)
)
$script:barSpec = @(
  [pscustomobject]@{ Id = 'select'; Label = '选区' },
  [pscustomobject]@{ Id = 'pen'; Label = '画笔' },
  [pscustomobject]@{ Id = 'rect'; Label = '矩形' },
  [pscustomobject]@{ Id = 'arrow'; Label = '箭头' },
  [pscustomobject]@{ Id = 'color'; Label = '' },
  [pscustomobject]@{ Id = 'sep'; Label = '' },
  [pscustomobject]@{ Id = 'undo'; Label = '撤销' },
  [pscustomobject]@{ Id = 'clear'; Label = '清空' },
  [pscustomobject]@{ Id = 'sep'; Label = '' },
  [pscustomobject]@{ Id = 'cancel'; Label = '取消' },
  [pscustomobject]@{ Id = 'done'; Label = '完成' }
)

function New-RoundPath($rect, $radius) {
  $path = New-Object System.Drawing.Drawing2D.GraphicsPath
  $d = $radius * 2
  if ($d -gt $rect.Width) { $d = $rect.Width }
  if ($d -gt $rect.Height) { $d = $rect.Height }
  $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
  $path.AddArc(($rect.Right - $d), $rect.Y, $d, $d, 270, 90)
  $path.AddArc(($rect.Right - $d), ($rect.Bottom - $d), $d, $d, 0, 90)
  $path.AddArc($rect.X, ($rect.Bottom - $d), $d, $d, 90, 90)
  $path.CloseFigure()
  return $path
}

# 工具栏贴在选区右下角（空间不够时自动翻到选区上方 / 内部），只在有选区时出现。
function Update-BarLayout {
  if (-not $script:hasRect) {
    $script:barRect = New-Object System.Drawing.Rectangle(0, 0, 0, 0)
    $script:barButtons = @()
    return
  }
  $pad = 8
  $gap = 2
  $height = 44
  $inner = $height - 10
  $total = $pad * 2
  $widths = @()
  foreach ($spec in $script:barSpec) {
    if ($spec.Id -eq 'sep') { $widths += 9; $total += 9; continue }
    if ($spec.Id -eq 'color') { $w = 34 } else { $w = [System.Windows.Forms.TextRenderer]::MeasureText([string]$spec.Label, $script:uiFont, [System.Drawing.Size]::Empty, [System.Windows.Forms.TextFormatFlags]::NoPadding).Width + 22 }
    if ($spec.Id -eq 'done') { $w += 6 }
    if ($spec.Id -eq 'cancel') { $w += 2 }
    $widths += $w
    $total += $w + $gap
  }
  $rect = $script:rect
  $left = $rect.Right - $total
  $top = $rect.Bottom + 10
  $maxLeft = [Math]::Max(4, $script:full.Width - $total - 4)
  $left = [int][Math]::Min([Math]::Max(4, $left), $maxLeft)
  if (($top + $height) -gt ($script:full.Height - 6)) {
    $above = $rect.Top - $height - 10
    if ($above -ge 6) {
      $top = $above
    } else {
      $top = [Math]::Max(6, $rect.Bottom - $height - 10)
    }
  }
  $script:barRect = New-Object System.Drawing.Rectangle($left, $top, $total, $height)

  $items = @()
  $x = $left + $pad
  for ($i = 0; $i -lt $script:barSpec.Count; $i++) {
    $spec = $script:barSpec[$i]
    $w = $widths[$i]
    if ($spec.Id -eq 'sep') {
      $items += [pscustomobject]@{ Id = 'sep'; Label = ''; Rect = (New-Object System.Drawing.Rectangle(($x + 4), ($top + 11), 1, ($height - 22))) }
      $x += $w
      continue
    }
    $items += [pscustomobject]@{
      Id = $spec.Id
      Label = $spec.Label
      Rect = (New-Object System.Drawing.Rectangle($x, ($top + 5), $w, $inner))
    }
    $x += $w + $gap
  }
  $script:barButtons = $items
}

function Get-BarButtonAt($x, $y) {
  foreach ($button in $script:barButtons) {
    if ($button.Id -ne 'sep' -and $button.Rect.Contains($x, $y)) { return $button }
  }
  return $null
}

function Draw-Toolbar($graphics) {
  if ($script:barRect.Width -le 0) { return }
  $bar = $script:barRect
  $shadowPath = New-RoundPath (New-Object System.Drawing.Rectangle($bar.X, ($bar.Y + 4), $bar.Width, $bar.Height)) 12
  $shadow = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(46, 0, 0, 0))
  $graphics.FillPath($shadow, $shadowPath)
  $shadow.Dispose()
  $shadowPath.Dispose()

  $path = New-RoundPath $bar 12
  $fill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
  $graphics.FillPath($fill, $path)
  $fill.Dispose()
  $border = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(235, 226, 229, 233), 1)
  $graphics.DrawPath($border, $path)
  $border.Dispose()
  $path.Dispose()

  $activeFill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 232, 241, 255))
  $hotFill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 242, 243, 245))
  $primaryFill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 60, 130, 255))
  $textIdle = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 32, 36, 44))
  $textMuted = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 150, 155, 165))
  $textActive = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 46, 106, 220))
  $textWhite = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
  $sepPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 233, 235, 239), 1)

  foreach ($button in $script:barButtons) {
    if ($button.Id -eq 'sep') {
      $graphics.DrawLine($sepPen, $button.Rect.X, $button.Rect.Y, $button.Rect.X, ($button.Rect.Y + $button.Rect.Height))
      continue
    }
    $disabled = $false
    if ($button.Id -eq 'undo' -or $button.Id -eq 'clear') { $disabled = $script:strokes.Count -eq 0 }
    $active = $button.Id -eq $script:tool
    $hot = $script:barHot -eq $button.Id

    $cell = New-Object System.Drawing.Rectangle($button.Rect.X, $button.Rect.Y, $button.Rect.Width, $button.Rect.Height)
    if ($button.Id -eq 'done') {
      $donePath = New-RoundPath $cell 8
      $graphics.FillPath($primaryFill, $donePath)
      $donePath.Dispose()
      [System.Windows.Forms.TextRenderer]::DrawText($graphics, $button.Label, $script:uiFont, $cell, [System.Drawing.Color]::White, [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPadding)
      continue
    }
    if ($button.Id -eq 'color') {
      if ($hot) {
        $colorPath = New-RoundPath $cell 8
        $graphics.FillPath($hotFill, $colorPath)
        $colorPath.Dispose()
      }
      $dot = New-Object System.Drawing.SolidBrush($script:color)
      $graphics.FillEllipse($dot, ($cell.X + 10), ($cell.Y + 5), 14, 14)
      $ring = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(60, 0, 0, 0), 1)
      $graphics.DrawEllipse($ring, ($cell.X + 10), ($cell.Y + 5), 14, 14)
      $dot.Dispose()
      $ring.Dispose()
      continue
    }
    if ($active -or $hot) {
      $cellPath = New-RoundPath $cell 8
      $graphics.FillPath($(if ($active) { $activeFill } else { $hotFill }), $cellPath)
      $cellPath.Dispose()
    }
    $brush = $textIdle
    if ($active) { $brush = $textActive }
    if ($disabled) { $brush = $textMuted }
    [System.Windows.Forms.TextRenderer]::DrawText($graphics, $button.Label, $script:uiFont, $cell, $brush.Color, [System.Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [System.Windows.Forms.TextFormatFlags]::VerticalCenter -bor [System.Windows.Forms.TextFormatFlags]::NoPadding)
  }

  $activeFill.Dispose()
  $hotFill.Dispose()
  $primaryFill.Dispose()
  $textIdle.Dispose()
  $textMuted.Dispose()
  $textActive.Dispose()
  $textWhite.Dispose()
  $sepPen.Dispose()
}

function Set-Tool($name) {
  $script:tool = $name
  if ($name -eq 'select') { $form.Cursor = [System.Windows.Forms.Cursors]::SizeAll } else { $form.Cursor = [System.Windows.Forms.Cursors]::Cross }
  $form.Invalidate()
}

function Invoke-BarButton($id) {
  switch ($id) {
    'select' { Set-Tool 'select' }
    'pen' { Set-Tool 'pen' }
    'rect' { Set-Tool 'rect' }
    'arrow' { Set-Tool 'arrow' }
    'color' {
      $index = [Array]::IndexOf($script:palette, $script:color)
      $script:color = $script:palette[($index + 1) % $script:palette.Count]
      $form.Invalidate()
    }
    'undo' {
      if ($script:strokes.Count -gt 0) { $script:strokes.RemoveAt($script:strokes.Count - 1) }
      $form.Invalidate()
    }
    'clear' { $script:strokes.Clear(); $form.Invalidate() }
    'cancel' { $script:cancelled = $true; $form.Close() }
    'done' { Complete-Selection }
  }
}

$form.add_Shown({
  Update-BarLayout
  $form.Activate()
  $form.Focus()
})

$form.add_Paint({
  param($sender, $e)
  $graphics = $e.Graphics
  $graphics.DrawImage($script:full, 0, 0, $script:full.Width, $script:full.Height)
  if (-not $script:hasRect) {
    $shade = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(110, 0, 0, 0))
    $graphics.FillRectangle($shade, 0, 0, $script:full.Width, $script:full.Height)
    $shade.Dispose()
  }
  Draw-Overlay $graphics
  if ($script:hasRect -and -not $script:mode) {
    # 工具栏跟着选区走：贴在选区右下角，空间不够时自动翻到上方或塞进选区下沿。
    # 拖动过程中先不画，松手后才出现，避免跟着光标抖。
    Update-BarLayout
    Draw-Toolbar $graphics
  } elseif (-not $script:hasRect) {
    $hintFont = New-Object System.Drawing.Font('Microsoft YaHei', 10)
    $hintText = '拖动鼠标框选区域  ·  Esc 取消'
    $hintSize = $graphics.MeasureString($hintText, $hintFont)
    $hx = [int](($script:full.Width - $hintSize.Width) / 2)
    $hy = $script:full.Height - 56
    $hintBox = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(220, 20, 24, 32))
    $graphics.FillRectangle($hintBox, $hx, $hy, ($hintSize.Width + 20), ($hintSize.Height + 10))
    $hintBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)
    $graphics.DrawString($hintText, $hintFont, $hintBrush, ($hx + 10), ($hy + 5))
    $hintBox.Dispose()
    $hintBrush.Dispose()
    $hintFont.Dispose()
  }
})

$form.add_MouseDown({
  param($sender, $e)
  if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Right) { $script:cancelled = $true; $sender.Close(); return }
  if ($e.Button -ne [System.Windows.Forms.MouseButtons]::Left) { return }

  if ($script:hasRect -and $script:barRect.Contains($e.X, $e.Y)) {
    $hit = Get-BarButtonAt $e.X $e.Y
    if ($hit) { Invoke-BarButton $hit.Id }
    return
  }

  if ($script:tool -eq 'select') {
    if ($script:hasRect) {
      $points = Get-RectPoints $script:rect
      foreach ($name in $handles) {
        $point = $points[$name]
        if ([Math]::Abs($e.X - $point.X) -le 10 -and [Math]::Abs($e.Y - $point.Y) -le 10) {
          $script:mode = 'resize'
          $script:handle = $name
          $script:base = $script:rect
          return
        }
      }
      if ($script:rect.Contains($e.X, $e.Y)) {
        $script:mode = 'move'
        $script:anchor = New-Object System.Drawing.Point($e.X, $e.Y)
        $script:base = $script:rect
        return
      }
    }
    $script:mode = 'new'
    $script:anchor = New-Object System.Drawing.Point($e.X, $e.Y)
    $script:rect = New-Object System.Drawing.Rectangle($e.X, $e.Y, 0, 0)
    $script:hasRect = $true
    return
  }

  if (-not $script:hasRect) { return }
  if (-not $script:rect.Contains($e.X, $e.Y)) { return }
  $stroke = [pscustomobject]@{
    Tool = $script:tool
    Color = $script:color
    Points = New-Object System.Collections.ArrayList
  }
  [void]$stroke.Points.Add((New-Object System.Drawing.Point($e.X, $e.Y)))
  [void]$script:strokes.Add($stroke)
  $script:mode = 'draw'
  $sender.Invalidate()
})

$form.add_MouseMove({
  param($sender, $e)
  if ($script:hasRect -and $script:barRect.Contains($e.X, $e.Y)) {
    $hit = Get-BarButtonAt $e.X $e.Y
    $next = if ($hit) { $hit.Id } else { '' }
    $form.Cursor = [System.Windows.Forms.Cursors]::Hand
    if ($next -ne $script:barHot) { $script:barHot = $next; $sender.Invalidate() }
    if (-not $script:mode) { return }
  } elseif ($script:barHot) {
    $script:barHot = ''
    if ($script:tool -eq 'select') { $form.Cursor = [System.Windows.Forms.Cursors]::SizeAll } else { $form.Cursor = [System.Windows.Forms.Cursors]::Cross }
    $sender.Invalidate()
    if (-not $script:mode) { return }
  }
  if (-not $script:mode) { return }
  if ($script:mode -eq 'new') {
    $x = [Math]::Min($script:anchor.X, $e.X)
    $y = [Math]::Min($script:anchor.Y, $e.Y)
    $w = [Math]::Abs($e.X - $script:anchor.X)
    $h = [Math]::Abs($e.Y - $script:anchor.Y)
    $script:rect = New-Object System.Drawing.Rectangle($x, $y, $w, $h)
    $script:hasRect = $true
  } elseif ($script:mode -eq 'move') {
    $dx = $e.X - $script:anchor.X
    $dy = $e.Y - $script:anchor.Y
    $x = [Math]::Max(0, [Math]::Min($script:base.X + $dx, $script:full.Width - $script:base.Width))
    $y = [Math]::Max(0, [Math]::Min($script:base.Y + $dy, $script:full.Height - $script:base.Height))
    $script:rect = New-Object System.Drawing.Rectangle($x, $y, $script:base.Width, $script:base.Height)
  } elseif ($script:mode -eq 'resize') {
    $left = $script:base.Left
    $top = $script:base.Top
    $right = $script:base.Right
    $bottom = $script:base.Bottom
    if ($script:handle.Contains('w')) { $left = $e.X }
    if ($script:handle.Contains('e')) { $right = $e.X }
    if ($script:handle.Contains('n')) { $top = $e.Y }
    if ($script:handle.Contains('s')) { $bottom = $e.Y }
    if ($right -lt $left) { $tmp = $left; $left = $right; $right = $tmp }
    if ($bottom -lt $top) { $tmp = $top; $top = $bottom; $bottom = $tmp }
    $left = [Math]::Max(0, [Math]::Min($left, $script:full.Width - 8))
    $top = [Math]::Max(0, [Math]::Min($top, $script:full.Height - 8))
    $right = [Math]::Max($left + 8, [Math]::Min($right, $script:full.Width))
    $bottom = [Math]::Max($top + 8, [Math]::Min($bottom, $script:full.Height))
    $script:rect = New-Object System.Drawing.Rectangle($left, $top, ($right - $left), ($bottom - $top))
  } elseif ($script:mode -eq 'draw') {
    if ($script:strokes.Count -eq 0) { return }
    $stroke = $script:strokes[$script:strokes.Count - 1]
    if ($stroke.Tool -eq 'pen') {
      [void]$stroke.Points.Add((New-Object System.Drawing.Point($e.X, $e.Y)))
    } else {
      if ($stroke.Points.Count -gt 1) { $stroke.Points.RemoveAt($stroke.Points.Count - 1) }
      [void]$stroke.Points.Add((New-Object System.Drawing.Point($e.X, $e.Y)))
    }
  }
  $sender.Invalidate()
})

$form.add_MouseUp({
  param($sender, $e)
  if (-not $script:mode) { return }
  if ($script:mode -eq 'new') {
    if ($script:rect.Width -lt 4 -or $script:rect.Height -lt 4) {
      $script:rect = New-Object System.Drawing.Rectangle(0, 0, $script:full.Width, $script:full.Height)
    }
  }
  $script:mode = ''
  $script:anchor = $null
  $script:base = $null
  $script:handle = ''
  Update-BarLayout
  $sender.Invalidate()
})

$form.add_KeyDown({
  param($sender, $e)
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Escape) { $script:cancelled = $true; $sender.Close(); return }
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) { Complete-Selection; return }
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::D2) { Set-Tool 'pen'; return }
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::D3) { Set-Tool 'rect'; return }
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::D4) { Set-Tool 'arrow'; return }
  if ($e.KeyCode -eq [System.Windows.Forms.Keys]::D1) { Set-Tool 'select'; return }
  if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::Z) {
    if ($script:strokes.Count -gt 0) { $script:strokes.RemoveAt($script:strokes.Count - 1) }
    $sender.Invalidate()
  }
  if ($e.Control -and $e.KeyCode -eq [System.Windows.Forms.Keys]::C) {
    try { [System.Windows.Forms.Clipboard]::SetImage((New-Crop)) } catch {}
  }
})

# 无人值守自检：直接给出选区 + 三笔涂鸦，走一遍「裁切 + 烧笔迹」。
try {
if ($script:autoRect) {
  $parts = $script:autoRect -split ','
  $script:rect = New-Object System.Drawing.Rectangle([int]$parts[0], [int]$parts[1], [int]$parts[2], [int]$parts[3])
  $script:hasRect = $true
  try { Save-Result } catch { $script:failure = $_.Exception.Message }
  if ($script:failure) { Write-Error $script:failure; exit 4 }
  exit 0
}

if ($script:selfTest) {
  $script:rect = New-Object System.Drawing.Rectangle(320, 240, 880, 560)
  $script:hasRect = $true
  $penStroke = [pscustomobject]@{ Tool = 'pen'; Color = [System.Drawing.Color]::FromArgb(255, 59, 48); Points = New-Object System.Collections.ArrayList }
  foreach ($i in 0..40) { [void]$penStroke.Points.Add((New-Object System.Drawing.Point((400 + $i * 12), (360 + [int](40 * [Math]::Sin($i / 4)))))) }
  [void]$script:strokes.Add($penStroke)
  $rectStroke = [pscustomobject]@{ Tool = 'rect'; Color = [System.Drawing.Color]::FromArgb(255, 214, 10); Points = New-Object System.Collections.ArrayList }
  [void]$rectStroke.Points.Add((New-Object System.Drawing.Point(700, 520)))
  [void]$rectStroke.Points.Add((New-Object System.Drawing.Point(1080, 700)))
  [void]$script:strokes.Add($rectStroke)
  $arrowStroke = [pscustomobject]@{ Tool = 'arrow'; Color = [System.Drawing.Color]::FromArgb(60, 130, 255); Points = New-Object System.Collections.ArrayList }
  [void]$arrowStroke.Points.Add((New-Object System.Drawing.Point(520, 640)))
  [void]$arrowStroke.Points.Add((New-Object System.Drawing.Point(760, 560)))
  [void]$script:strokes.Add($arrowStroke)
  try { Save-Result } catch { $script:failure = $_.Exception.Message }
  if ($script:failure) { Write-Error $script:failure; exit 4 }
  exit 0
}

if ($env:DSH_SHOT_DEMO -eq '1') {
  $script:rect = New-Object System.Drawing.Rectangle(360, 260, 900, 560)
  $script:hasRect = $true
}

try {
  [void]$form.ShowDialog()
} catch {
  $script:failure = $_.Exception.Message
} finally {
  $form.Dispose()
  $script:full.Dispose()
}

if ($script:failure) { Write-Error $script:failure; exit 4 }
if ($script:cancelled) { exit 2 }
if (-not (Test-Path $script:out)) { exit 2 }
exit 0
} finally {
  Restore-AppWindows
}


