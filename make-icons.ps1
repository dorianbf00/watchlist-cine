# Génère les icônes de l'app (dossier app/) à partir du logo W :
#  - W jaune néon (#E2FF01) : 3 barres en haut, 2 blocs décalés en bas, sur une grille de 5 colonnes (97 x 75)
#  - icône : W centré sur un dégradé vertical blanc -> bleu (#1744FB)
# Produit les PNG (iPhone, Android, onglet) + les SVG (logo de la page, icône d'onglet nette).
Add-Type -AssemblyName System.Drawing
$dir = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'app'
New-Item -ItemType Directory -Force $dir | Out-Null

# Rectangles du W dans un repère 97 x 75 (relevés sur le logo d'origine)
$W = @(
  @(0, 0, 19.4, 50), @(38.8, 0, 19.4, 50), @(77.6, 0, 19.4, 50),   # 3 barres du haut
  @(19.4, 50, 19.4, 25), @(58.2, 50, 19.4, 25)                     # 2 blocs du bas
)
$Yellow = [Drawing.Color]::FromArgb(226, 255, 1)
$Top = [Drawing.Color]::FromArgb(250, 250, 250)
$Blue = [Drawing.Color]::FromArgb(23, 68, 251)

function New-Icon([int]$S, [string]$Path, [double]$WScale = 97 / 128) {
  $bmp = New-Object Drawing.Bitmap $S, $S
  $g = [Drawing.Graphics]::FromImage($bmp)
  $g.SmoothingMode = 'AntiAlias'; $g.PixelOffsetMode = 'HighQuality'
  $rect = New-Object Drawing.Rectangle 0, 0, $S, $S
  $grad = New-Object Drawing.Drawing2D.LinearGradientBrush $rect, $Top, $Blue, ([Drawing.Drawing2D.LinearGradientMode]::Vertical)
  $g.FillRectangle($grad, $rect)
  # W centré, largeur = WScale x taille
  $k = $S * $WScale / 97
  $ox = ($S - 97 * $k) / 2; $oy = ($S - 75 * $k) / 2
  $yb = New-Object Drawing.SolidBrush $Yellow
  foreach ($r in $W) { $g.FillRectangle($yb, [single]($ox + $r[0] * $k), [single]($oy + $r[1] * $k), [single]($r[2] * $k), [single]($r[3] * $k)) }
  $bmp.Save($Path, [Drawing.Imaging.ImageFormat]::Png)
  $g.Dispose(); $bmp.Dispose()
}

New-Icon 180 (Join-Path $dir 'icon-180.png')                 # iPhone (écran d'accueil)
New-Icon 192 (Join-Path $dir 'icon-192.png')                 # Android
New-Icon 512 (Join-Path $dir 'icon-512.png')                 # Android (grande)
New-Icon 512 (Join-Path $dir 'icon-maskable-512.png') 0.62   # Android, formes rondes : W plus petit (zone sûre)
New-Icon 64  (Join-Path $dir 'favicon.png')                  # onglet (navigateurs sans SVG)
New-Icon 32  (Join-Path $dir 'favicon-32.png')

# SVG : rectangles du W
$rects = ($W | ForEach-Object { '<rect x="{0}" y="{1}" width="{2}" height="{3}"/>' -f $_[0], $_[1], $_[2], $_[3] }) -join ''
$utf8 = New-Object Text.UTF8Encoding($false)
# Logo seul (fond transparent)
[IO.File]::WriteAllText((Join-Path $dir 'logo.svg'), "<svg xmlns=""http://www.w3.org/2000/svg"" viewBox=""0 0 97 75""><g fill=""#E2FF01"">$rects</g></svg>", $utf8)
# Icône d'onglet nette (dégradé + W)
$icon = "<svg xmlns=""http://www.w3.org/2000/svg"" viewBox=""0 0 128 128""><defs><linearGradient id=""b"" x1=""0"" y1=""0"" x2=""0"" y2=""1""><stop offset=""0"" stop-color=""#FAFAFA""/><stop offset=""1"" stop-color=""#1744FB""/></linearGradient></defs><rect width=""128"" height=""128"" fill=""url(#b)""/><g fill=""#E2FF01"" transform=""translate(15.5 26.5)"">$rects</g></svg>"
[IO.File]::WriteAllText((Join-Path $dir 'favicon.svg'), $icon, $utf8)
Get-ChildItem $dir | Select-Object Name, Length | Format-Table -AutoSize | Out-String
