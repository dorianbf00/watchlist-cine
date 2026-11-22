<#
  watchlist-cine.ps1
  Croise ta watchlist Letterboxd avec les séances du Rétro Projecteur (Paris)
  sur les N prochains jours, génère la page index.html (à partir de page-template.html)
  et, en option, envoie une notification push via ntfy.

  Usage :  powershell -ExecutionPolicy Bypass -File watchlist-cine.ps1 -User <pseudo_letterboxd>
#>
param(
  [Parameter(Mandatory = $true)][string]$User,
  [int]$Days = 3,
  [string]$OutDir,
  [string]$NtfyTopic,   # si fourni : envoie une notification push via ntfy.sh
  [string]$PageUrl,     # URL publique de la page (ouverte quand on touche la notif)
  [string]$NotifOut,    # écrit le contenu de la notif (titre/message/lien) dans ce fichier JSON
  [switch]$NoOpen
)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutDir) { $OutDir = $ScriptDir }

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36'

function Get-Utf8([string]$Url) {
  $r = Invoke-WebRequest -Uri $Url -UserAgent $UA -UseBasicParsing -TimeoutSec 30
  $ms = New-Object IO.MemoryStream
  $r.RawContentStream.Position = 0
  $r.RawContentStream.CopyTo($ms)
  [Text.Encoding]::UTF8.GetString($ms.ToArray())
}

function Normalize([string]$s) {
  if (-not $s) { return '' }
  $d = $s.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object Text.StringBuilder
  foreach ($c in $d.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne 'NonSpacingMark') { [void]$sb.Append($c) }
  }
  ($sb.ToString().ToLower() -replace '&', 'and' -replace '[^a-z0-9]', '')
}

# --- 1. Watchlist Letterboxd ---------------------------------------------
$watch = @()
$page = 1
while ($true) {
  $url = "https://letterboxd.com/$User/watchlist/page/$page/"
  try { $html = Get-Utf8 $url } catch { if ($page -eq 1) { throw "Watchlist introuvable pour '$User' ($url) : $_" } else { break } }
  $found = [regex]::Matches($html, 'data-item-name="([^"]+)"[^>]*?data-item-slug="([^"]+)"')
  if ($found.Count -eq 0) { break }
  foreach ($m in $found) {
    $name = [System.Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
    $year = $null
    if ($name -match '^(.*) \((\d{4})\)$') { $name = $Matches[1]; $year = [int]$Matches[2] }
    $watch += [pscustomobject]@{ Name = $name; Year = $year; Slug = $m.Groups[2].Value; Key = (Normalize $name) }
  }
  $page++
  if ($page -gt 100) { break }
  Start-Sleep -Milliseconds 400
}
Write-Host "Watchlist : $($watch.Count) films"

# --- 2. Séances Rétro Projecteur -----------------------------------------
$results = [ordered]@{}
$today = (Get-Date).Date
$dayList = @()
for ($i = 0; $i -lt $Days; $i++) {
  $day = $today.AddDays($i)
  $iso = $day.ToString('yyyy-MM-dd')
  $dayList += $iso
  $movies = (Get-Utf8 "https://leretroprojecteur.com/api/movies/all-by-day/$iso") | ConvertFrom-Json
  foreach ($mv in $movies) {
    $keys = @((Normalize $mv.title), (Normalize $mv.original_title)) | Where-Object { $_ }
    $match = $watch | Where-Object {
      ($keys -contains $_.Key) -and ((-not $_.Year) -or (-not $mv.year) -or ([math]::Abs($_.Year - [int]$mv.year) -le 1))
    } | Select-Object -First 1
    if (-not $match) { continue }

    if (-not $results.Contains($mv.id)) {
      $results[$mv.id] = [ordered]@{
        id = $mv.id; title = $mv.title; original = $mv.original_title; year = $mv.year
        directors = $mv.directors; countries = $mv.countries; slug = $match.Slug
        poster = $null; rating = $null; runtime = $null
        seances = New-Object System.Collections.ArrayList
      }
    }
    foreach ($th in $mv.showtimes_theater) {
      $times = [object[]]@($th.seances.PSObject.Properties | ForEach-Object { [double]$_.Value.time } | Sort-Object)
      [void]$results[$mv.id].seances.Add([ordered]@{
        date = $iso; theater = $th.name; zip = $th.zipcode; bank = $th.neighborhood; times = $times })
    }
  }
}

# --- 3. Infos Letterboxd (affiche, note, durée) ---------------------------
foreach ($f in $results.Values) {
  try {
    $h = Get-Utf8 "https://letterboxd.com/film/$($f.slug)/"
    if ($h -match '"image":"(https://a\.ltrbxd\.com/resized/film-poster/[^"]+)"') { $f.poster = $Matches[1] }
    if ($h -match '"ratingValue":([0-9.]+)') { $f.rating = [double]$Matches[1] }
    if ($h -match '(\d+)&nbsp;mins') { $f.runtime = [int]$Matches[1] }
  } catch { Write-Host "Infos Letterboxd indisponibles pour $($f.slug)" }
  Start-Sleep -Milliseconds 300
}

# --- 4. Page HTML -----------------------------------------------------------
$data = [ordered]@{
  user = $User; generated = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ss')
  days = $dayList; watchlistCount = $watch.Count
  films = [object[]]@($results.Values)
}
$json = ($data | ConvertTo-Json -Depth 8 -Compress) -replace '</', '<\/'
$template = [IO.File]::ReadAllText((Join-Path $ScriptDir 'page-template.html'), [Text.Encoding]::UTF8)
$outFile = Join-Path $OutDir 'index.html'
[IO.File]::WriteAllText($outFile, $template.Replace('/*__DATA__*/null', $json), (New-Object Text.UTF8Encoding($false)))

$films = @($results.Values)
Write-Host "$($films.Count) film(s) trouvés -> $outFile"
foreach ($f in $films) { Write-Host (" - {0} ({1})" -f $f.title, $f.year) }

# --- 5. Notification téléphone (ntfy) ----------------------------------------
$names = ($films | Select-Object -First 5 | ForEach-Object { $_.title }) -join ' · '
if ($films.Count -gt 5) { $names += ' …' }
$notif = [ordered]@{
  title   = if ($films) { "🎬 $($films.Count) film(s) de ta watchlist au ciné" } else { 'Rien de ta watchlist au ciné' }
  message = if ($films) { $names } else { 'Aucun film de ta watchlist ces 3 prochains jours.' }
  click   = if ($PageUrl) { $PageUrl } else { 'https://leretroprojecteur.com/' }
}
if ($NotifOut) { [IO.File]::WriteAllText($NotifOut, ($notif | ConvertTo-Json), (New-Object Text.UTF8Encoding($false))) }
if ($NtfyTopic) {
  $notif.topic = $NtfyTopic
  $payload = $notif | ConvertTo-Json
  Invoke-RestMethod -Uri 'https://ntfy.sh/' -Method Post -ContentType 'application/json; charset=utf-8' `
    -Body ([Text.Encoding]::UTF8.GetBytes($payload)) | Out-Null
  Write-Host "Notification ntfy envoyée"
}

if (-not $NoOpen) { Start-Process $outFile }
