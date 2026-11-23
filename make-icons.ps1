# Génère le logo et les icônes de l'app (dossier app/) à partir du logo officiel (Figma, fichier WATCHLIST, frame 11) :
#  - W : 5 blocs reliés par de petits arrondis concaves, dégradé vertical #D5FF00 -> #F6FF00, ombre intérieure légère
#  - fond de l'icône : dégradé vertical blanc #FFFFFF -> bleu électrique #0033FF
# Produit les PNG (iPhone, Android, onglet) + les SVG (logo de la page, icône d'onglet).
Add-Type -AssemblyName System.Drawing
$dir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'app'
New-Item -ItemType Directory -Force $dir | Out-Null

# Tracé exact du W (repère 96.774 x 75), copié depuis Figma
$WPath = 'M 0 0 L 19.354 0 L 19.354 49.596 L 0 49.596 L 0 0 Z M 19.354 49.596 L 38.709 49.596 L 38.709 75 L 19.354 75 L 19.354 49.596 Z M 38.709 0 L 58.064 0 L 58.064 49.596 L 38.709 49.596 L 38.709 0 Z M 58.064 49.596 L 77.419 49.596 L 77.419 75 L 58.064 75 L 58.064 49.596 Z M 77.419 0 L 96.774 0 L 96.774 49.596 L 77.419 49.596 L 77.419 0 Z M 0 49.596 L 19.354 49.596 C 19.354 49.596 19.354 64.717 19.354 57.157 C 19.354 49.596 7.560 49.596 0 49.596 Z M 38.709 42.036 L 38.709 49.596 C 38.709 49.596 23.588 49.596 31.149 49.596 C 38.709 49.596 38.709 49.596 38.709 42.036 Z M 26.915 49.596 L 19.354 49.596 C 19.354 49.596 19.354 34.475 19.354 42.036 C 19.354 49.596 19.354 49.596 26.915 49.596 Z M 38.709 57.157 L 38.709 49.596 C 38.709 49.596 53.830 49.596 46.270 49.596 C 38.709 49.596 38.709 49.596 38.709 57.157 Z M 50.504 49.596 L 58.064 49.596 C 58.064 49.596 58.064 64.717 58.064 57.157 C 58.064 49.596 58.064 49.596 50.504 49.596 Z M 65.625 49.596 L 58.064 49.596 C 58.064 49.596 58.064 34.475 58.064 42.036 C 58.064 49.596 58.064 49.596 65.625 49.596 Z M 77.419 42.036 L 77.419 49.596 C 77.419 49.596 62.298 49.596 69.858 49.596 C 77.419 49.596 77.419 49.596 77.419 42.036 Z M 77.419 57.157 L 77.419 49.596 C 77.419 49.596 104.334 49.596 96.774 49.596 C 89.213 49.596 77.419 49.596 77.419 57.157 Z'
$WW = 96.774; $WH = 75

$Lime1 = [Drawing.Color]::FromArgb(213, 255, 0)     # #D5FF00 (haut du W)
$Lime2 = [Drawing.Color]::FromArgb(246, 255, 0)     # #F6FF00 (bas du W)
$Sky1 = [Drawing.Color]::FromArgb(255, 255, 255)    # #FFFFFF (haut du fond)
$Sky2 = [Drawing.Color]::FromArgb(0, 51, 255)       # #0033FF (bas du fond)

# Chemin SVG (M, L, C, Z) -> GraphicsPath, mis à l'échelle k et décalé (ox, oy)
function New-WPath([double]$k, [double]$ox, [double]$oy) {
  $gp = New-Object Drawing.Drawing2D.GraphicsPath ([Drawing.Drawing2D.FillMode]::Winding)
  $tok = $WPath -split '\s+'; $i = 0; $cx = 0; $cy = 0
  $P = { param($x, $y) New-Object Drawing.PointF ([single]($ox + $x * $k)), ([single]($oy + $y * $k)) }
  while ($i -lt $tok.Count) {
    switch ($tok[$i]) {
      'M' { $gp.StartFigure(); $cx = [double]$tok[$i + 1]; $cy = [double]$tok[$i + 2]; $i += 3 }
      'L' { $x = [double]$tok[$i + 1]; $y = [double]$tok[$i + 2]; $gp.AddLine((& $P $cx $cy), (& $P $x $y)); $cx = $x; $cy = $y; $i += 3 }
      'C' { $x1 = [double]$tok[$i + 1]; $y1 = [double]$tok[$i + 2]; $x2 = [double]$tok[$i + 3]; $y2 = [double]$tok[$i + 4]; $x = [double]$tok[$i + 5]; $y = [double]$tok[$i + 6]
            $gp.AddBezier((& $P $cx $cy), (& $P $x1 $y1), (& $P $x2 $y2), (& $P $x $y)); $cx = $x; $cy = $y; $i += 7 }
      'Z' { $gp.CloseFigure(); $i += 1 }
      default { $i += 1 }
    }
  }
  $gp
}

function New-Icon([int]$S, [string]$Path, [double]$WScale = 98.11 / 128) {
  $bmp = New-Object Drawing.Bitmap $S, $S
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
  $rect = New-Object Drawing.Rectangle 0, 0, $S, $S
  $g.FillRectangle((New-Object Drawing.Drawing2D.LinearGradientBrush $rect, $Sky1, $Sky2, ([Drawing.Drawing2D.LinearGradientMode]::Vertical)), $rect)
  # W centré (dans Figma : x 16, y 26 sur 128)
  $k = $S * $WScale / 98.11
  $ox = $S * 16 / 128 + ($S * 98.11 / 128 - 98.11 * $k) / 2; $oy = ($S - $WH * $k) / 2 + ($S * 0.5 / 128)
  $wp = New-WPath $k $ox $oy
  $wr = New-Object Drawing.RectangleF ([single]$ox), ([single]$oy), ([single]($WW * $k)), ([single]($WH * $k))
  $g.FillPath((New-Object Drawing.Drawing2D.LinearGradientBrush $wr, $Lime1, $Lime2, ([Drawing.Drawing2D.LinearGradientMode]::Vertical)), $wp)
  # Ombre intérieure légère (Figma : noir 25 %, flou 2,4) : traits de plus en plus fins, découpés à l'intérieur du W
  $g.SetClip($wp)
  $r = 2.4 * $k
  foreach ($n in 1..5) {
    $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(9, 0, 0, 0)), ([single]($r * 1.1 * $n / 5))
    $pen.LineJoin = 'Round'; $g.DrawPath($pen, $wp); $pen.Dispose()
  }
  $g.ResetClip()
  $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}

New-Icon 180 (Join-Path $dir 'icon-180.png')                 # iPhone (écran d'accueil)
New-Icon 192 (Join-Path $dir 'icon-192.png')                 # Android
New-Icon 512 (Join-Path $dir 'icon-512.png')                 # Android (grande)
New-Icon 512 (Join-Path $dir 'icon-maskable-512.png') 0.62   # Android, formes rondes : W plus petit (zone sûre)
New-Icon 64  (Join-Path $dir 'favicon.png')                  # onglet (navigateurs sans SVG)
New-Icon 32  (Join-Path $dir 'favicon-32.png')

$utf8 = New-Object Text.UTF8Encoding($false)
$defsW = '<linearGradient id="lime" x1="0" y1="0" x2="0" y2="1"><stop offset="0" stop-color="#D5FF00"/><stop offset="1" stop-color="#F6FF00"/></linearGradient>' +
  '<filter id="inner" x="-5%" y="-5%" width="110%" height="110%"><feGaussianBlur in="SourceAlpha" stdDeviation="1.2" result="b"/><feComposite in="SourceAlpha" in2="b" operator="out" result="e"/><feFlood flood-color="#000" flood-opacity=".25"/><feComposite in2="e" operator="in" result="s"/><feComposite in="s" in2="SourceGraphic" operator="over"/></filter>'
# Logo seul (fond transparent)
[IO.File]::WriteAllText((Join-Path $dir 'logo.svg'), "<svg xmlns=""http://www.w3.org/2000/svg"" viewBox=""0 0 $WW $WH""><defs>$defsW</defs><path d=""$WPath"" fill=""url(#lime)"" filter=""url(#inner)""/></svg>", $utf8)
# Icône d'onglet (dégradé + W)
$icon = "<svg xmlns=""http://www.w3.org/2000/svg"" viewBox=""0 0 128 128""><defs><linearGradient id=""sky"" x1=""0"" y1=""0"" x2=""0"" y2=""1""><stop offset=""0"" stop-color=""#FFFFFF""/><stop offset=""1"" stop-color=""#0033FF""/></linearGradient>$defsW</defs><rect width=""128"" height=""128"" fill=""url(#sky)""/><path d=""$WPath"" transform=""translate(16 26)"" fill=""url(#lime)"" filter=""url(#inner)""/></svg>"
[IO.File]::WriteAllText((Join-Path $dir 'favicon.svg'), $icon, $utf8)
Get-ChildItem $dir | Select-Object Name, Length | Format-Table -AutoSize | Out-String
