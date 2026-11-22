# Génère les icônes de l'app (dossier app/) : fond vert citron, pellicule de film, grand "W".
Add-Type -AssemblyName System.Drawing
$dir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'app'
New-Item -ItemType Directory -Force $dir | Out-Null

function New-Icon([int]$S, [string]$Path, [double]$Pad = 0) {
  $bmp = New-Object Drawing.Bitmap $S, $S
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.TextRenderingHint = 'AntiAliasGridFit'; $g.InterpolationMode = 'HighQualityBicubic'
  $green = [Drawing.Color]::FromArgb(226, 255, 70)
  $gray  = [Drawing.Color]::FromArgb(106, 106, 109)
  $black = [Drawing.Color]::FromArgb(3, 3, 3)
  $g.Clear($green)

  # zone utile (marge pour les icônes "maskable" Android)
  $o = $S * $Pad; $w = $S - 2 * $o
  # bandes de pellicule en haut et en bas
  $band = $w * 0.17
  $bb = New-Object Drawing.SolidBrush $black
  $g.FillRectangle($bb, [single]$o, [single]$o, [single]$w, [single]$band)
  $g.FillRectangle($bb, [single]$o, [single]($o + $w - $band), [single]$w, [single]$band)
  # perforations
  $gb = New-Object Drawing.SolidBrush $green
  $n = 6; $hw = $w / ($n * 2); $hh = $band * 0.42
  for ($i = 0; $i -lt $n; $i++) {
    $x = $o + $hw * 0.5 + $i * 2 * $hw
    foreach ($y in @(($o + ($band - $hh) / 2), ($o + $w - $band + ($band - $hh) / 2))) {
      $g.FillRectangle($gb, [single]$x, [single]$y, [single]$hw, [single]$hh)
    }
  }
  # grand W gris, centré
  $font = New-Object Drawing.Font 'Arial Black', ([single]($w * 0.52)), ([Drawing.FontStyle]::Bold), ([Drawing.GraphicsUnit]::Pixel)
  $sf = New-Object Drawing.StringFormat; $sf.Alignment = 'Center'; $sf.LineAlignment = 'Center'
  $rect = New-Object Drawing.RectangleF ([single]$o), ([single]($o + $w * 0.035)), ([single]$w), ([single]$w)
  $g.DrawString('W', $font, (New-Object Drawing.SolidBrush $gray), $rect, $sf)

  $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}

New-Icon 180 (Join-Path $dir 'icon-180.png')            # iPhone (apple-touch-icon)
New-Icon 192 (Join-Path $dir 'icon-192.png')            # Android
New-Icon 512 (Join-Path $dir 'icon-512.png')            # Android (grande)
New-Icon 512 (Join-Path $dir 'icon-maskable-512.png') 0.1  # Android, formes rondes/arrondies
New-Icon 64  (Join-Path $dir 'favicon.png')
Get-ChildItem $dir | Select-Object Name, Length
