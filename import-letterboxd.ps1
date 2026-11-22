<#
  import-letterboxd.ps1
  À lancer une fois (ou de temps en temps) avec l'export officiel Letterboxd :
  Letterboxd > Settings > Data > Export your data  ->  letterboxd-<pseudo>-<date>.zip

  Produit, à côté du script :
   - taste-data.json : tes films vus, tes notes et tes coups de cœur (clé = adresse Letterboxd du film)
   - lb-films.json   : caractéristiques de chaque film (genres, thèmes, réalisateur, acteurs, pays, année, note moyenne)
  Ces deux fichiers servent au classement "pour toi" de watchlist-cine.ps1, qui les complète ensuite
  automatiquement avec tes nouvelles notes (flux RSS + derniers films vus).

  Usage : powershell -ExecutionPolicy Bypass -File import-letterboxd.ps1 -ExportZip <chemin du zip>
#>
param([Parameter(Mandatory = $true)][string]$ExportZip, [int]$DelayMs = 1000)
$ErrorActionPreference = 'Stop'
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36'
$Curl = if ($env:OS -eq 'Windows_NT') { 'curl.exe' } else { 'curl' }
$Tmp = [IO.Path]::GetTempFileName()

# --- Lecture de l'export (dans un dossier temporaire à part) ---
$dir = Join-Path ([IO.Path]::GetTempPath()) ("lbexport-" + [guid]::NewGuid())
Expand-Archive $ExportZip -DestinationPath $dir
$ratings = @(Import-Csv (Join-Path $dir 'ratings.csv') -Encoding UTF8)
$watched = @(Import-Csv (Join-Path $dir 'watched.csv') -Encoding UTF8)
$likes = if (Test-Path (Join-Path $dir 'likes\films.csv')) { @(Import-Csv (Join-Path $dir 'likes\films.csv') -Encoding UTF8) } else { @() }
Remove-Item $dir -Recurse -Force
Write-Host "Export : $($watched.Count) films vus, $($ratings.Count) notes, $($likes.Count) coups de cœur"

# --- Fichiers existants (on complète, on ne repart pas de zéro) ---
function Read-Json([string]$path) {
  $h = @{}
  if (Test-Path $path) { try { (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $h[$_.Name] = $_.Value } } catch {} }
  $h
}
$tastePath = Join-Path $ScriptDir 'taste-data.json'
$featPath = Join-Path $ScriptDir 'lb-films.json'
$taste = Read-Json $tastePath
$films = @{}; if ($taste.films) { $taste.films.PSObject.Properties | ForEach-Object { $films[$_.Name] = $_.Value } }
$boxd = @{}; if ($taste.boxd) { $taste.boxd.PSObject.Properties | ForEach-Object { $boxd[$_.Name] = $_.Value } }
$feats = Read-Json $featPath

function Save-All {
  $o = [ordered]@{}; foreach ($k in ($feats.Keys | Sort-Object)) { $o[$k] = $feats[$k] }
  [IO.File]::WriteAllText($featPath, ($o | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
  $fo = [ordered]@{}; foreach ($k in ($films.Keys | Sort-Object)) { $fo[$k] = $films[$k] }
  $bo = [ordered]@{}; foreach ($k in ($boxd.Keys | Sort-Object)) { $bo[$k] = $boxd[$k] }
  $t = [ordered]@{ updated = (Get-Date).ToString('yyyy-MM-dd'); films = $fo; boxd = $bo }
  [IO.File]::WriteAllText($tastePath, ($t | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
}

# Caractéristiques d'une fiche film (mêmes règles que watchlist-cine.ps1 > Get-LbFeatures)
function Read-Features([string]$p) {
  $o = [ordered]@{ y = 0; avg = $null; g = @(); t = @(); c = @(); d = @(); a = @() }
  if ($p -match 'og:title" content="[^"]*\((\d{4})\)') { $o.y = [int]$Matches[1] }
  if ($p -match '"ratingValue":([0-9.]+)') { $o.avg = [double]$Matches[1] }
  if ($p -match '"genre":\[([^\]]*)\]') { $o.g = @([regex]::Matches($Matches[1], '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) }
  if ($p -match '"countryOfOrigin":\[(.*?)\]') { $o.c = @([regex]::Matches($Matches[1], '"name":"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) }
  if ($p -match '"director":\[(.*?)\]') { $o.d = @([regex]::Matches($Matches[1], '"name":"([^"]+)"') | ForEach-Object { [regex]::Unescape($_.Groups[1].Value) }) }
  $o.t = @([regex]::Matches($p, 'href="/films/(?:theme|mini-theme)/[^"]+"[^>]*>([^<]+)</a>') | ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value.Trim()) } | Select-Object -Unique)
  $o.a = @([regex]::Matches($p, 'href="/actor/([^/"]+)/"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique -First 6)
  [pscustomobject]$o
}

# --- Tous les films vus : on résout le lien court boxd.it -> adresse du film, et on lit sa fiche ---
$rateBy = @{}; foreach ($r in $ratings) { $rateBy[$r.'Letterboxd URI'] = [double]$r.Rating }
$likeBy = @{}; foreach ($l in $likes) { $likeBy[$l.'Letterboxd URI'] = $true }
$uris = @($watched | ForEach-Object { $_.'Letterboxd URI' }) + @($ratings | ForEach-Object { $_.'Letterboxd URI' }) | Select-Object -Unique
$todo = @($uris | Where-Object { -not $boxd.ContainsKey(($_ -split '/')[-1]) -or -not $feats.ContainsKey($boxd[($_ -split '/')[-1]]) })
Write-Host "À récupérer : $($todo.Count) fiches (environ $([math]::Ceiling($todo.Count * ($DelayMs + 600) / 60000)) min)"

$i = 0; $fails = 0
foreach ($u in $uris) {
  $code = ($u -split '/')[-1]
  if (-not $boxd.ContainsKey($code) -or -not $feats.ContainsKey($boxd[$code])) {
    $res = & $Curl -s -L --compressed --max-time 30 -A $UA -o $Tmp -w '%{http_code} %{url_effective}' $u
    $body = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($Tmp))
    if ($res -match '^200 https://letterboxd\.com/film/([^/]+)/' -and $body -notmatch '<title>Just a moment') {
      $boxd[$code] = $Matches[1]
      $feats[$Matches[1]] = Read-Features $body
    } else {
      $fails++
      Write-Host "  échec ($res) pour $u"
      if ($fails -ge 15) { Write-Host 'Trop d''échecs (anti-robot ?) : arrêt, relance plus tard pour compléter.'; break }
      Start-Sleep -Seconds 10
    }
    Start-Sleep -Milliseconds $DelayMs
    if ((++$i % 50) -eq 0) { Save-All; Write-Host "  $i / $($todo.Count)" }
  }
  if ($boxd.ContainsKey($code)) {
    $slug = $boxd[$code]
    $films[$slug] = [pscustomobject]@{ r = if ($rateBy.ContainsKey($u)) { $rateBy[$u] } else { $null }; liked = [bool]$likeBy[$u] }
  }
}
Save-All
Write-Host "Terminé : $($films.Count) films dans taste-data.json ($(@($films.Values | Where-Object { $_.r }).Count) notés), $($feats.Count) fiches dans lb-films.json"
