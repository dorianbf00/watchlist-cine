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
# Salles retenues : Paris intra-muros (75xxx) ET carte UGC Illimité acceptée
$ugcList = @{}   # nom normalisé -> adresse (ou '' si inconnue)
Get-Content (Join-Path $ScriptDir 'cinemas-ugc.txt') -Encoding UTF8 | ForEach-Object { $_.Trim() } |
  Where-Object { $_ -and -not $_.StartsWith('#') } | ForEach-Object {
    $parts = $_ -split '\|', 2
    $ugcList[(Normalize $parts[0].Trim())] = if ($parts.Count -gt 1) { $parts[1].Trim() } else { '' }
  }
function Get-Address($th) {
  $a = $ugcList[(Normalize $th.name)]
  if ($a) { return $a } else { return "$($th.zipcode) Paris" }
}
function Test-Theater($th) {
  if ("$($th.zipcode)" -notmatch '^75\d{3}$') { return $false }
  $n = Normalize $th.name
  return ($n.StartsWith('ugc') -or $n.StartsWith('mk2') -or $ugcList.ContainsKey($n))
}

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
    $theaters = @($mv.showtimes_theater | Where-Object { Test-Theater $_ })
    if (-not $theaters) { continue }

    if (-not $results.Contains($mv.id)) {
      $results[$mv.id] = [ordered]@{
        id = $mv.id; title = $mv.title; original = $mv.original_title; year = $mv.year
        directors = $mv.directors; countries = $mv.countries; slug = $match.Slug
        poster = $null; still = $null; rating = $null; runtime = $null
        seances = New-Object System.Collections.ArrayList
      }
    }
    foreach ($th in $theaters) {
      $times = [object[]]@($th.seances.PSObject.Properties | ForEach-Object { [double]$_.Value.time } | Sort-Object)
      [void]$results[$mv.id].seances.Add([ordered]@{
        date = $iso; theater = $th.name; zip = $th.zipcode; bank = $th.neighborhood
        address = (Get-Address $th); times = $times; ics = $null })
    }
  }
}

# --- 3. Infos Letterboxd (affiche, note, durée) ---------------------------
foreach ($f in $results.Values) {
  # L'affiche est dans les données structurées (JSON-LD) de la fiche Letterboxd ; 3 essais en cas d'erreur réseau
  for ($try = 1; $try -le 3 -and -not $f.poster; $try++) {
    try {
      $h = Get-Utf8 "https://letterboxd.com/film/$($f.slug)/"
      if ($h -match '"image":"(https://a\.ltrbxd\.com/resized/[^"]+)"') { $f.poster = $Matches[1] }
      if ($h -match '"ratingValue":([0-9.]+)') { $f.rating = [double]$Matches[1] }
      if ($h -match '(\d+)&nbsp;mins') { $f.runtime = [int]$Matches[1] }
    } catch { Write-Host "Letterboxd indisponible pour $($f.slug) (essai $try)" }
    if (-not $f.poster) { Start-Sleep -Seconds (2 * $try) }
  }
  # Dernier recours : la photo du film utilisée par le Rétro Projecteur
  if (-not $f.poster) {
    try {
      $h = Get-Utf8 "https://leretroprojecteur.com/film/$($f.id)"
      if ($h -match 'og:image" content="([^"]+)"') { $f.still = $Matches[1] }
    } catch {}
    Write-Host "Pas d'affiche Letterboxd pour $($f.slug) -> photo de secours : $([bool]$f.still)"
  }
  Start-Sleep -Milliseconds 300
}

# --- 4. Un fichier calendrier (.ics) par séance --------------------------------
# Toucher une séance sur la page ouvre ce fichier : l'iPhone propose alors "Ajouter au calendrier".
function Esc-Ics([string]$s) { ($s -replace '\\', '\\' -replace ';', '\;' -replace ',', '\,' -replace "`r?`n", '\n') }
function Fold-Ics([string]$line) {
  # Lignes de 75 octets max (norme iCalendar), coupées sans casser les caractères accentués
  $out = New-Object Text.StringBuilder; $cur = ''
  foreach ($ch in $line.ToCharArray()) {
    if ([Text.Encoding]::UTF8.GetByteCount($cur + $ch) -gt 73) { [void]$out.Append($cur + "`r`n "); $cur = '' }
    $cur += $ch
  }
  [void]$out.Append($cur); $out.ToString()
}
$icsDir = Join-Path $OutDir 'ics'
if (Test-Path $icsDir) { Remove-Item $icsDir -Recurse -Force }
New-Item -ItemType Directory -Force $icsDir | Out-Null
$stamp = (Get-Date).ToUniversalTime().ToString("yyyyMMdd'T'HHmmss'Z'")
$vtz = @('BEGIN:VTIMEZONE', 'TZID:Europe/Paris',
  'BEGIN:DAYLIGHT', 'TZOFFSETFROM:+0100', 'TZOFFSETTO:+0200', 'TZNAME:CEST', 'DTSTART:19700329T020000', 'RRULE:FREQ=YEARLY;BYMONTH=3;BYDAY=-1SU', 'END:DAYLIGHT',
  'BEGIN:STANDARD', 'TZOFFSETFROM:+0200', 'TZOFFSETTO:+0100', 'TZNAME:CET', 'DTSTART:19701025T030000', 'RRULE:FREQ=YEARLY;BYMONTH=10;BYDAY=-1SU', 'END:STANDARD',
  'END:VTIMEZONE')
foreach ($f in $results.Values) {
  foreach ($s in $f.seances) {
    $files = @()
    foreach ($t in $s.times) {
      $h = [math]::Floor($t); $m = [int][math]::Round(($t - $h) * 60); if ($m -eq 60) { $h++; $m = 0 }
      $start = [datetime]::ParseExact($s.date, 'yyyy-MM-dd', $null).AddHours($h).AddMinutes($m)
      $dur = if ($f.runtime) { $f.runtime } else { 120 }
      $end = $start.AddMinutes($dur + 20)   # + ~20 min de pubs/bandes-annonces
      $thSlug = (Normalize $s.theater)
      $name = '{0}-{1}-{2:00}{3:00}-{4}.ics' -f $f.id, $s.date, $h, $m, $thSlug
      $desc = "$($f.title) ($($f.year)) – $($f.directors)`n$dur min`nhttps://leretroprojecteur.com/film/$($f.id)`nhttps://letterboxd.com/film/$($f.slug)/"
      $lines = @('BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//watchlist-cine//FR', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH') + $vtz + @(
        'BEGIN:VEVENT',
        "UID:$($name -replace '\.ics$','')@watchlist-cine",
        "DTSTAMP:$stamp",
        "DTSTART;TZID=Europe/Paris:$($start.ToString("yyyyMMdd'T'HHmmss"))",
        "DTEND;TZID=Europe/Paris:$($end.ToString("yyyyMMdd'T'HHmmss"))",
        "SUMMARY:$(Esc-Ics "🎬 $($f.title)")",
        "LOCATION:$(Esc-Ics "$($s.theater), $($s.address)")",
        "DESCRIPTION:$(Esc-Ics $desc)",
        "URL:https://leretroprojecteur.com/film/$($f.id)",
        'BEGIN:VALARM', 'TRIGGER:-PT1H', 'ACTION:DISPLAY', "DESCRIPTION:$(Esc-Ics "$($f.title) dans 1h – $($s.theater)")", 'END:VALARM',
        'END:VEVENT', 'END:VCALENDAR')
      $ics = ($lines | ForEach-Object { Fold-Ics $_ }) -join "`r`n"
      [IO.File]::WriteAllText((Join-Path $icsDir $name), $ics + "`r`n", (New-Object Text.UTF8Encoding($false)))
      $files += $name
    }
    $s.ics = [object[]]$files
  }
}

# --- 5. Page HTML -----------------------------------------------------------
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

# --- 6. Notification téléphone (ntfy) ----------------------------------------
$names = ($films | Select-Object -First 5 | ForEach-Object { $_.title }) -join ' · '
if ($films.Count -gt 5) { $names += ' …' }
$notif = [ordered]@{
  title   = if ($films) { "🎬 $($films.Count) film(s) de ta watchlist au ciné" } else { 'Rien de ta watchlist au ciné' }
  message = if ($films) { $names } else { 'Aucun film de ta watchlist ces 3 prochains jours.' }
  click   = if ($PageUrl) { $PageUrl } else { 'https://leretroprojecteur.com/' }
}
$notif.actions = @(@{ action = 'view'; label = 'Ouvrir la page'; url = $notif.click })
if ($NotifOut) { [IO.File]::WriteAllText($NotifOut, ($notif | ConvertTo-Json -Depth 4), (New-Object Text.UTF8Encoding($false))) }
if ($NtfyTopic) {
  $notif.topic = $NtfyTopic
  $payload = $notif | ConvertTo-Json -Depth 4
  Invoke-RestMethod -Uri 'https://ntfy.sh/' -Method Post -ContentType 'application/json; charset=utf-8' `
    -Body ([Text.Encoding]::UTF8.GetBytes($payload)) | Out-Null
  Write-Host "Notification ntfy envoyée"
}

if (-not $NoOpen) { Start-Process $outFile }
