Add-Type -AssemblyName System.Drawing
$size = 1024
$bmp = New-Object System.Drawing.Bitmap($size, $size)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
$rect = New-Object System.Drawing.Rectangle(0, 0, $size, $size)
$c1 = [System.Drawing.Color]::FromArgb(255, 90, 30, 180)
$c2 = [System.Drawing.Color]::FromArgb(255, 30, 70, 200)
$brush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, $c1, $c2, 45.0)
$g.FillRectangle($brush, $rect)
$fmt = New-Object System.Drawing.StringFormat
$fmt.Alignment = [System.Drawing.StringAlignment]::Center
$fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
$f1 = New-Object System.Drawing.Font('Segoe UI', 400, [System.Drawing.FontStyle]::Bold)
$white = [System.Drawing.Brushes]::White
$g.DrawString('FM', $f1, $white, (New-Object System.Drawing.RectangleF(-40, -160, ($size + 80), ($size - 220))), $fmt)
$fonts = (New-Object System.Drawing.Text.InstalledFontCollection).Families | ForEach-Object { $_.Name }
$cjk = $fonts | Where-Object { $_ -match 'YaHei|SimHei|SimSun|Microsoft JhengHei|DengXian' } | Select-Object -First 1
if (-not $cjk) { $cjk = 'Segoe UI' }
$f2 = New-Object System.Drawing.Font($cjk, 96, [System.Drawing.FontStyle]::Bold)
$g.DrawString('黄果短剧', $f2, $white, (New-Object System.Drawing.RectangleF(0, 760, $size, 200)), $fmt)
$g.Dispose()
$outPath = 'D:\ai 项目\huangguo\FmHuangguo\FmHuangguo\Assets.xcassets\AppIcon.appiconset\AppIcon.png'
$bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
$bmp.Dispose()
Write-Host "OK: $outPath (cjk font: $cjk)"
