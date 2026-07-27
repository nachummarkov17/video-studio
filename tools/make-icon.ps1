# Generates VideoStudio.ico - a branded icon (teal card with a play triangle and
# two caption bars) at several sizes, packed into one .ico (PNG-compressed entries).
Add-Type -AssemblyName System.Drawing

function New-IconPng([int]$S) {
    $bmp = New-Object System.Drawing.Bitmap($S, $S, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode     = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.Clear([System.Drawing.Color]::Transparent)

    # rounded-rect card with a vertical teal gradient
    $pad = [int]($S * 0.06)
    $rad = [double]($S * 0.20)
    $rect = New-Object System.Drawing.RectangleF($pad, $pad, ($S - 2*$pad), ($S - 2*$pad))
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $rad
    $path.AddArc($rect.X, $rect.Y, $d, $d, 180, 90)
    $path.AddArc($rect.Right - $d, $rect.Y, $d, $d, 270, 90)
    $path.AddArc($rect.Right - $d, $rect.Bottom - $d, $d, $d, 0, 90)
    $path.AddArc($rect.X, $rect.Bottom - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    $cTop = [System.Drawing.Color]::FromArgb(255, 74, 179, 162)   # #4AB3A2
    $cBot = [System.Drawing.Color]::FromArgb(255, 43, 120, 108)   # #2B786C
    $brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $cTop, $cBot, 90)
    $g.FillPath($brush, $path)

    # white play triangle (rounded join), sitting in the upper-middle
    $white = [System.Drawing.Color]::FromArgb(255, 255, 255, 255)
    $wBrush = New-Object System.Drawing.SolidBrush($white)
    $cx = $S * 0.5; $cy = $S * 0.42; $t = $S * 0.15
    $tri = @(
        (New-Object System.Drawing.PointF(($cx - $t*0.85), ($cy - $t))),
        (New-Object System.Drawing.PointF(($cx - $t*0.85), ($cy + $t))),
        (New-Object System.Drawing.PointF(($cx + $t*1.05), $cy))
    )
    $penJoin = New-Object System.Drawing.Pen($white, [single]($S*0.055))
    $penJoin.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
    $g.FillPolygon($wBrush, $tri)
    $g.DrawPolygon($penJoin, $tri)

    # two caption bars near the bottom (the "captions")
    function BarPath([double]$x,[double]$y,[double]$w,[double]$h) {
        $r = $h/2.0
        $p = New-Object System.Drawing.Drawing2D.GraphicsPath
        $p.AddArc($x, $y, $r*2, $h, 90, 180)
        $p.AddArc($x + $w - $r*2, $y, $r*2, $h, 270, 180)
        $p.CloseFigure(); return $p
    }
    $barH = $S * 0.062
    $b1 = BarPath ($S*0.28) ($S*0.66) ($S*0.44) $barH
    $b2 = BarPath ($S*0.28) ($S*0.77) ($S*0.30) $barH
    $g.FillPath($wBrush, $b1)
    $g.FillPath($wBrush, $b2)

    $g.Dispose()
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
    return ,$ms.ToArray()
}

$sizes = @(256, 64, 48, 32, 16)
$pngs  = @{}
foreach ($s in $sizes) { $pngs[$s] = New-IconPng $s }

$out = Join-Path $PSScriptRoot '..\VideoStudio.ico'
$out = [System.IO.Path]::GetFullPath($out)
$fs = [System.IO.File]::Open($out, [System.IO.FileMode]::Create)
$bw = New-Object System.IO.BinaryWriter($fs)
# ICONDIR
$bw.Write([uint16]0); $bw.Write([uint16]1); $bw.Write([uint16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
foreach ($s in $sizes) {
    $len = $pngs[$s].Length
    $dim = if ($s -ge 256) { 0 } else { $s }
    $bw.Write([byte]$dim); $bw.Write([byte]$dim)     # width, height (0 = 256)
    $bw.Write([byte]0); $bw.Write([byte]0)           # colors, reserved
    $bw.Write([uint16]1); $bw.Write([uint16]32)      # planes, bpp
    $bw.Write([uint32]$len); $bw.Write([uint32]$offset)
    $offset += $len
}
foreach ($s in $sizes) { $bw.Write($pngs[$s]) }
$bw.Flush(); $fs.Close()
Write-Host "Wrote $out ($([System.IO.FileInfo]::new($out).Length) bytes, sizes: $($sizes -join ', '))"
