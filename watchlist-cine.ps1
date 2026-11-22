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

# Clés de comparaison d'un titre, tolérantes aux variantes courantes entre Letterboxd et le Rétro Projecteur :
#  - chiffres romains <-> arabes ("Evil Dead II" = "Evil Dead 2")
#  - article en tête ("The Thing" = "Thing", "Le Mépris" = "Mépris")
#  - sous-titre (partie avant ":" ou " - "), utilisée seulement avec la même année exacte
$Roman = @{ ii = '2'; iii = '3'; iv = '4'; v = '5'; vi = '6'; vii = '7'; viii = '8'; ix = '9'; x = '10' }
$Articles = @('the', 'a', 'an', 'le', 'la', 'les', 'l', 'un', 'une', 'der', 'die', 'das', 'el', 'il', 'lo')
function Get-Words([string]$s) {
  if (-not $s) { return @() }
  $d = $s.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object Text.StringBuilder
  foreach ($c in $d.ToCharArray()) {
    if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne 'NonSpacingMark') { [void]$sb.Append($c) }
  }
  $w = @(($sb.ToString().ToLower() -replace '&', ' and ' -replace "['’]", ' ') -split '[^a-z0-9]+' | Where-Object { $_ })
  for ($i = 0; $i -lt $w.Count; $i++) {
    if ($Roman.ContainsKey($w[$i])) { $w[$i] = $Roman[$w[$i]] }
    elseif ($w[$i] -eq 'i' -and $i -eq $w.Count - 1 -and $i -gt 0) { $w[$i] = '1' }   # "Vol. I" en fin de titre
  }
  return $w
}
function Get-TitleKeys([string]$s) {
  $keys = New-Object System.Collections.Generic.HashSet[string]
  $w = Get-Words $s
  if (-not $w) { return [pscustomobject]@{ Full = ''; Strong = $keys; Sub = '' } }
  [void]$keys.Add(($w -join ''))
  if ($w.Count -gt 1 -and $Articles -contains $w[0]) { [void]$keys.Add((($w | Select-Object -Skip 1) -join '')) }
  $sub = ''
  $parts = $s -split '\s*[:–—]\s*|\s+-\s+', 2
  if ($parts.Count -gt 1) { $sub = ((Get-Words $parts[0]) -join ''); if ($sub.Length -lt 5) { $sub = '' } }
  [pscustomobject]@{ Full = ($w -join ''); Strong = $keys; Sub = $sub }
}
# Renvoie 'exact' (même titre, chiffres romains compris), 'loose' (article/sous-titre) ou $null
function Test-SameFilm($a, [int]$aYear, $b, [int]$bYear) {
  $yearOk = (-not $aYear) -or (-not $bYear) -or ([math]::Abs($aYear - $bYear) -le 1)
  if ($yearOk -and $a.Full -and $a.Full -eq $b.Full) { return 'exact' }
  if ($yearOk) { foreach ($k in $a.Strong) { if ($b.Strong.Contains($k)) { return 'loose' } } }
  # Sous-titre : "Twin Peaks: Fire Walk with Me" ~ "Twin Peaks" — seulement si même année exacte
  if ($aYear -and $bYear -and $aYear -eq $bYear) {
    if ($a.Sub -and $b.Strong.Contains($a.Sub)) { return 'loose' }
    if ($b.Sub -and $a.Strong.Contains($b.Sub)) { return 'loose' }
  }
  return $null
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
    $watch += [pscustomobject]@{ Name = $name; Year = $year; Slug = $m.Groups[2].Value; Keys = (Get-TitleKeys $name) }
  }
  $page++
  if ($page -gt 100) { break }
  Start-Sleep -Milliseconds 400
}
Write-Host "Watchlist : $($watch.Count) films"
# Index clé -> films de la watchlist (titre complet, sans article, et sous-titre)
$wIndex = @{}
foreach ($w in $watch) {
  $ks = @($w.Keys.Strong) + @($w.Keys.Sub | Where-Object { $_ })
  foreach ($k in $ks) { if (-not $wIndex.ContainsKey($k)) { $wIndex[$k] = @() }; $wIndex[$k] += $w }
}

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

function Add-Seances($entry, $theaters, [string]$iso) {
  foreach ($th in $theaters) {
    $times = @($th.seances.PSObject.Properties | ForEach-Object { [double]$_.Value.time })
    $same = $entry.seances | Where-Object { $_.date -eq $iso -and $_.theater -eq $th.name } | Select-Object -First 1
    if ($same) { $same.times = [object[]]@(($same.times + $times) | Sort-Object -Unique); continue }
    [void]$entry.seances.Add([ordered]@{
      date = $iso; theater = $th.name; zip = $th.zipcode; bank = $th.neighborhood
      address = (Get-Address $th); times = [object[]]@($times | Sort-Object -Unique); ics = $null })
  }
}

$results = [ordered]@{}   # films de la watchlist
$others = [ordered]@{}    # autres films à l'affiche dans les mêmes salles
$today = (Get-Date).Date
$dayList = @()
for ($i = 0; $i -lt $Days; $i++) {
  $day = $today.AddDays($i)
  $iso = $day.ToString('yyyy-MM-dd')
  $dayList += $iso
  $movies = (Get-Utf8 "https://leretroprojecteur.com/api/movies/all-by-day/$iso") | ConvertFrom-Json
  foreach ($mv in $movies) {
    $mvKeys = @((Get-TitleKeys $mv.title), (Get-TitleKeys $mv.original_title))
    $mvYear = if ($mv.year) { [int]$mv.year } else { 0 }
    $cands = @()
    foreach ($k in $mvKeys) {
      foreach ($s in $k.Strong) { if ($wIndex.ContainsKey($s)) { $cands += $wIndex[$s] } }
      if ($k.Sub -and $wIndex.ContainsKey($k.Sub)) { $cands += $wIndex[$k.Sub] }
    }
    # On garde la meilleure correspondance : 'exact' l'emporte sur 'loose'
    $match = $null; $kind = $null
    foreach ($w in $cands) {
      $wYear = if ($w.Year) { [int]$w.Year } else { 0 }
      foreach ($k in $mvKeys) {
        $r = Test-SameFilm $w.Keys $wYear $k $mvYear
        if ($r -eq 'exact') { $match = $w; $kind = 'exact'; break }
        if ($r -eq 'loose' -and -not $match) { $match = $w; $kind = 'loose' }
      }
      if ($kind -eq 'exact') { break }
    }
    $theaters = @($mv.showtimes_theater | Where-Object { Test-Theater $_ })
    if (-not $theaters) { continue }

    if ($match) {
      # Une seule carte par film Letterboxd : le Rétro Projecteur a parfois 2 fiches pour le même film
      $coll = $results; $key = $match.Slug
    } else {
      # Pas dans la watchlist -> section "Aussi à l'affiche" en bas de la page
      $coll = $others; $key = "rp:$($mv.id)"
    }
    if (-not $coll.Contains($key)) {
      $coll[$key] = [ordered]@{
        id = $mv.id; title = $mv.title; original = $mv.original_title; year = $mv.year
        directors = $mv.directors; countries = $mv.countries; slug = if ($match) { $match.Slug } else { $null }
        poster = $null; still = $null; rating = $null; runtime = $null
        seances = New-Object System.Collections.ArrayList
        exact = $false
      }
    }
    $entry = $coll[$key]
    if ($kind -eq 'exact' -and -not $entry.exact) {
      # La fiche dont le titre correspond exactement à Letterboxd donne le titre affiché
      $entry.exact = $true; $entry.id = $mv.id; $entry.title = $mv.title; $entry.original = $mv.original_title
    }
    Add-Seances $entry $theaters $iso
  }
}

# --- 3. Infos Letterboxd (affiche, note, durée) + vérification du réalisateur ----
# Noms de famille normalisés d'une liste de réalisateurs ("Jan Komasa, X Y" -> komasa, y)
function Get-Surnames([string[]]$names) {
  @($names | ForEach-Object { $_ -split '\s*,\s*|\s+(?:et|and|&)\s+' } | Where-Object { $_ } |
    ForEach-Object { $w = @(Get-Words $_); if ($w) { $w[-1] } })
}
$rejected = @()
foreach ($f in @($results.Values)) {
  # L'affiche est dans les données structurées (JSON-LD) de la fiche Letterboxd ; 3 essais en cas d'erreur réseau
  $lbDirectors = @()
  for ($try = 1; $try -le 3 -and -not $f.poster; $try++) {
    try {
      $h = Get-Utf8 "https://letterboxd.com/film/$($f.slug)/"
      if ($h -match '"image":"(https://a\.ltrbxd\.com/resized/[^"]+)"') { $f.poster = $Matches[1] }
      if ($h -match '"ratingValue":([0-9.]+)') { $f.rating = [double]$Matches[1] }
      if ($h -match '(\d+)&nbsp;mins') { $f.runtime = [int]$Matches[1] }
      if ($h -match '"director":\[(.*?)\]') {
        $lbDirectors = @([regex]::Matches($Matches[1], '"name":"([^"]+)"') | ForEach-Object { [regex]::Unescape($_.Groups[1].Value) })
      }
    } catch { Write-Host "Letterboxd indisponible pour $($f.slug) (essai $try)" }
    if (-not $f.poster) { Start-Sleep -Seconds (2 * $try) }
  }
  # Correspondance approximative (article/sous-titre) : on vérifie le réalisateur pour éviter les homonymes
  # (ex. "The Good Boy" de Komasa ≠ "Good Boy" de Leonberg). Translittérations tolérées (4 premières lettres).
  $rp = Get-Surnames @($f.directors); $lb = Get-Surnames $lbDirectors
  $pre = { param($n) if ($n.Length -gt 4) { $n.Substring(0, 4) } else { $n } }
  $lbPre = @($lb | ForEach-Object { & $pre $_ })
  if (-not $f.exact -and $rp -and $lb -and -not ($rp | Where-Object { $lbPre -contains (& $pre $_) })) {
    Write-Host "Écarté : $($f.title) ($($f.directors)) ≠ watchlist $($f.slug) ($($lbDirectors -join ', '))"
    $rejected += $f.slug; continue
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
# Les films écartés (homonymes) rejoignent les "autres films"
foreach ($s in $rejected) {
  $f = $results[$s]; $results.Remove($s)
  $f.slug = $null; $f.poster = $null; $f.rating = $null; $f.runtime = $null
  if (-not $others.Contains("rp:$($f.id)")) { $others["rp:$($f.id)"] = $f }
}
Write-Host "Autres films à l'affiche (hors watchlist) : $($others.Count)"

# --- 4. Un fichier calendrier (.ics) par séance --------------------------------
# Toucher une séance sur la page ouvre ce fichier : l'iPhone propose alors "Ajouter au calendrier".
function Esc-Ics([string]$s) { ($s -replace '\\', '\\' -replace ';', '\;' -replace ',', '\,' -replace "`r?`n", '\n') }
function Fold-Ics([string]$line) {
  # Lignes de 75 octets max (norme iCalendar), coupées sans casser les caractères accentués
  if ([Text.Encoding]::UTF8.GetByteCount($line) -le 73) { return $line }
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
foreach ($f in @($results.Values) + @($others.Values)) {
  foreach ($s in $f.seances) {
    $files = @()
    foreach ($t in $s.times) {
      $h = [math]::Floor($t); $m = [int][math]::Round(($t - $h) * 60); if ($m -eq 60) { $h++; $m = 0 }
      $start = [datetime]::ParseExact($s.date, 'yyyy-MM-dd', $null).AddHours($h).AddMinutes($m)
      $dur = if ($f.runtime) { $f.runtime } else { 120 }
      $end = $start.AddMinutes($dur + 20)   # + ~20 min de pubs/bandes-annonces
      $thSlug = (Normalize $s.theater)
      $name = '{0}-{1}-{2:00}{3:00}-{4}.ics' -f $f.id, $s.date, $h, $m, $thSlug
      $desc = "$($f.title) ($($f.year)) – $($f.directors)" + $(if ($f.runtime) { "`n$dur min" } else { '' }) +
        "`nhttps://leretroprojecteur.com/film/$($f.id)" + $(if ($f.slug) { "`nhttps://letterboxd.com/film/$($f.slug)/" } else { '' })
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
  others = [object[]]@($others.Values)
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
