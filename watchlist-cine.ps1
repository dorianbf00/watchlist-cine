<#
  watchlist-cine.ps1
  Croise ta watchlist Letterboxd avec les séances du Rétro Projecteur (Paris)
  sur les N prochains jours, génère la page index.html (à partir de page-template.html)
  et, en option, envoie une notification push via ntfy.

  Usage :  powershell -ExecutionPolicy Bypass -File watchlist-cine.ps1 -User <pseudo_letterboxd>
#>
param(
  [Parameter(Mandatory = $true)][string]$User,
  [int]$Days = 7,
  [string]$OutDir,
  [string]$NtfyTopic,   # si fourni : envoie une notification push via ntfy.sh
  [string]$PageUrl,     # URL publique de la page (ouverte quand on touche la notif)
  [string]$NotifOut,    # écrit le contenu de la notif (titre/message/lien) dans ce fichier JSON
  [string]$CachePath,   # cache des fiches Letterboxd trouvées (par défaut lb-cache.json à côté du script)
  [switch]$NoOpen
)
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $OutDir) { $OutDir = $ScriptDir }

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36'

# Téléchargement d'une page en UTF-8. On passe par curl (présent sur Windows 10+ et sur les serveurs GitHub) :
# l'anti-robot de Letterboxd (Cloudflare) bloque parfois le client HTTP de PowerShell, mais pas curl.
$Curl = if ($env:OS -eq 'Windows_NT') { 'curl.exe' } else { 'curl' }
$TmpFile = [IO.Path]::GetTempFileName()
function Get-Utf8([string]$Url) {
  $code = & $Curl -s -L --compressed --max-time 30 -A $UA -H 'Accept-Language: fr-FR,fr;q=0.9,en;q=0.8' -o $TmpFile -w '%{http_code}' $Url
  $body = [Text.Encoding]::UTF8.GetString([IO.File]::ReadAllBytes($TmpFile))
  if ("$code" -ne '200' -or $body -match '<title>Just a moment') { throw "HTTP $code $Url" }
  $body
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
# --- 3a. Fiche Letterboxd des autres films : affiche + 2e chance de correspondance -------
# On reconstruit l'adresse Letterboxd à partir du titre (original puis français), on vérifie l'année
# et le réalisateur, puis on compare la FICHE (pas le titre) avec la watchlist : "Mark Dixon, détective"
# est bien "Where the Sidewalk Ends", "L'Eclipse" est "L'eclisse", etc.
$cachePath = if ($CachePath) { $CachePath } else { Join-Path $ScriptDir 'lb-cache.json' }
$cache = @{}
if (Test-Path $cachePath) {
  try { (Get-Content $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cache[$_.Name] = $_.Value } } catch {}
}
$watchBySlug = @{}; foreach ($w in $watch) { $watchBySlug[$w.Slug] = $w }
$RomanOf = @{ '2' = 'ii'; '3' = 'iii'; '4' = 'iv'; '5' = 'v'; '6' = 'vi'; '7' = 'vii'; '8' = 'viii'; '9' = 'ix'; '10' = 'x' }
$ArabicOf = @{}; foreach ($k in $RomanOf.Keys) { $ArabicOf[$RomanOf[$k]] = $k }

function Get-LbSlug([string]$s) {
  $d = $s.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object Text.StringBuilder
  foreach ($c in $d.ToCharArray()) { if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne 'NonSpacingMark') { [void]$sb.Append($c) } }
  (($sb.ToString().ToLower() -replace "['’]", '' -replace '&', 'and' -replace '[^a-z0-9]+', '-').Trim('-'))
}
function Read-LbPage([string]$p) {
  $o = [ordered]@{ slug = $null; year = 0; poster = $null; rating = $null; runtime = $null; directors = @() }
  if ($p -match 'og:url" content="https://letterboxd\.com/film/([^/"]+)/') { $o.slug = $Matches[1] }
  if ($p -match 'og:title" content="[^"]*\((\d{4})\)') { $o.year = [int]$Matches[1] }
  if ($p -match '"image":"(https://a\.ltrbxd\.com/resized/[^"]+)"') { $o.poster = $Matches[1] }
  if ($p -match '"ratingValue":([0-9.]+)') { $o.rating = [double]$Matches[1] }
  if ($p -match '(\d+)&nbsp;mins') { $o.runtime = [int]$Matches[1] }
  if ($p -match '"director":\[(.*?)\]') { $o.directors = @([regex]::Matches($Matches[1], '"name":"([^"]+)"') | ForEach-Object { [regex]::Unescape($_.Groups[1].Value) }) }
  [pscustomobject]$o
}
function Test-SameDirector([string]$rpDirectors, [string[]]$lbDirectors) {
  $rp = Get-Surnames @($rpDirectors); $lb = Get-Surnames $lbDirectors
  if (-not $rp -or -not $lb) { return $true }   # info manquante : on ne bloque pas
  $pre = { param($n) if ($n.Length -gt 4) { $n.Substring(0, 4) } else { $n } }
  $lbPre = @($lb | ForEach-Object { & $pre $_ })
  return [bool]($rp | Where-Object { $lbPre -contains (& $pre $_) })
}
# Vrai "page introuvable" (404), par opposition à une erreur réseau ou un blocage temporaire
function Test-NotFound($err) {
  return ("$err" -match '^HTTP 404 ')
}
function Find-LbFilm($f, $tmdbId) {
  # 1) Identifiant TMDB donné par le Rétro Projecteur -> Letterboxd redirige vers la bonne fiche (le plus fiable)
  if ($tmdbId) {
    try {
      $info = Read-LbPage (Get-Utf8 "https://letterboxd.com/tmdb/$tmdbId/")
      if ($info.slug) { return $info }
    } catch { if (-not (Test-NotFound $_)) { $script:LbError = $true } }
  }
  # 2) Adresse reconstruite à partir du titre original puis français (+ variante chiffres romains)
  $cands = New-Object System.Collections.Generic.List[string]
  foreach ($t in (@($f.original, $f.title) | Where-Object { $_ } | Select-Object -Unique)) {
    $s = Get-LbSlug $t; if (-not $s) { continue }
    $vars = @($s)
    # "Evil Dead 2" <-> "evil-dead-ii"
    if ($s -match '^(.*)-(\d+)$' -and $RomanOf.ContainsKey($Matches[2])) { $vars += "$($Matches[1])-$($RomanOf[$Matches[2]])" }
    elseif ($s -match '^(.*)-([ivx]+)$' -and $ArabicOf.ContainsKey($Matches[2])) { $vars += "$($Matches[1])-$($ArabicOf[$Matches[2]])" }
    foreach ($v in $vars) { foreach ($c in @("$v-$($f.year)", $v)) { if (-not $cands.Contains($c)) { $cands.Add($c) } } }
  }
  foreach ($c in $cands) {
    try { $p = Get-Utf8 "https://letterboxd.com/film/$c/" } catch { if (-not (Test-NotFound $_)) { $script:LbError = $true }; Start-Sleep -Milliseconds 150; continue }
    $info = Read-LbPage $p
    if (-not $info.slug) { $info.slug = $c }
    if ($info.year -and $f.year -and [math]::Abs($info.year - [int]$f.year) -gt 1) { continue }
    if (-not (Test-SameDirector $f.directors $info.directors)) { continue }
    return $info
  }
  return $null
}
# Fiche Rétro Projecteur : identifiant TMDB + photo du film (image de partage), si ce n'est pas l'image générique du site
function Read-RpPage($f) {
  $o = @{ tmdb = $null; still = $null }
  try {
    $p = Get-Utf8 "https://leretroprojecteur.com/film/$($f.id)"
    if ($p -match '\\"tmdb_id\\":(\d+)') { $o.tmdb = $Matches[1] }
    if ($p -match 'og:image" content="([^"]+)"' -and $Matches[1] -notmatch 'opengraph-image') { $o.still = $Matches[1] }
  } catch {}
  $o
}
# Dernier recours : image principale de l'article Wikipédia du film (souvent l'affiche)
function Find-WikiImage($f) {
  # Titres essayés : complet, puis sans sous-titre ("Vivre sa vie: Film en douze tableaux" -> "Vivre sa vie")
  $short = { param($s) if ($s) { ($s -split '\s*[:–—(]\s*|\s+-\s+|\s+/\s+', 2)[0].Trim() } }
  $tries = @(@('fr', $f.title), @('en', $f.original), @('fr', $f.original),
             @('fr', (& $short $f.title)), @('en', (& $short $f.original))) |
    Where-Object { $_[1] -and $_[1].Length -ge 3 }
  if ($script:WikiLimited) { return $null }
  $seen = @{}
  foreach ($t in $tries) {
    if ($seen["$($t[0])|$($t[1])"]) { continue }; $seen["$($t[0])|$($t[1])"] = 1
    Start-Sleep -Milliseconds 400
    $q = [uri]::EscapeDataString("$($t[1]) $($f.year) film")
    $u = "https://$($t[0]).wikipedia.org/w/api.php?action=query&format=json&generator=search&gsrsearch=$q&gsrlimit=3&prop=pageimages&piprop=original&pilicense=any"
    $j = $null
    foreach ($attempt in 1..2) {
      try {
        $r = Invoke-WebRequest -Uri $u -UserAgent 'watchlist-cine/1.0 (projet perso)' -UseBasicParsing -TimeoutSec 30
        $j = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray()) | ConvertFrom-Json
        break
      } catch {
        if ($env:WC_DEBUG) { Write-Host "  Wikipédia ($($t[0]), $($t[1])) : $_" }
        if ("$_" -notmatch 'too many requests') { break }
        if ($attempt -eq 2) { $script:WikiLimited = $true; return $null }
        Start-Sleep -Seconds 8
      }
    }
    if (-not $j -or -not $j.query) { continue }
    $want = (Get-Words $t[1]) -join ''
    foreach ($pg in ($j.query.pages.PSObject.Properties.Value | Sort-Object index)) {
      $img = $pg.original.source
      if (-not $img -or $img -match '\.svg$') { continue }
      # Le titre de l'article doit être exactement celui du film, éventuellement suivi de "(film)" / "(film, 1962)"
      $pt = (Get-Words $pg.title) -join ''
      if ($pt -in @($want, "${want}film", "$want$($f.year)film", "${want}film$($f.year)", "$want$($f.year)")) { return $img }
    }
  }
  return $null
}
function Merge-Seances($dst, $src) {
  foreach ($s in $src.seances) {
    $same = $dst.seances | Where-Object { $_.date -eq $s.date -and $_.theater -eq $s.theater } | Select-Object -First 1
    if ($same) { $same.times = [object[]]@(($same.times + $s.times) | Sort-Object -Unique) } else { [void]$dst.seances.Add($s) }
  }
}

$now = Get-Date; $looked = 0; $moved = @()
foreach ($key in @($others.Keys)) {
  $f = $others[$key]
  $c = $cache[$f.id]
  # Déjà trouvé avec une affiche -> on garde. Sinon on retente (immédiatement si l'entrée date
  # d'une ancienne version du script, sinon au bout de 7 jours).
  $fresh = $c -and ($c.poster -or ($c.v -ge 2 -and ($now - [datetime]$c.t).TotalDays -lt 7))
  if (-not $fresh) {
    $script:LbError = $false
    $rp = Read-RpPage $f
    $info = Find-LbFilm $f $rp.tmdb; $looked++
    $img = $null
    if (-not $info.poster -and -not $rp.still) { $img = Find-WikiImage $f }
    # Échec réseau/blocage (pas un vrai "introuvable") : on retentera au prochain passage
    $v = if ((-not $info.slug -and $script:LbError) -or ($script:WikiLimited -and -not $info.poster -and -not $rp.still -and -not $img)) { 1 } else { 2 }
    $c = [pscustomobject]@{ v = $v; slug = $info.slug; poster = $info.poster; rating = $info.rating; runtime = $info.runtime
      still = if ($rp.still) { $rp.still } else { $img }; t = $now.ToString('yyyy-MM-dd') }
    $cache[$f.id] = $c
    Start-Sleep -Milliseconds 250
  }
  $f.still = $c.still
  if (-not $c.slug) { continue }
  $f.slug = $c.slug; $f.poster = $c.poster; $f.rating = $c.rating; $f.runtime = $c.runtime
  if ($watchBySlug.ContainsKey($c.slug)) {
    # Titre différent, mais c'est bien un film de la watchlist
    Write-Host "Rattrapé via la fiche Letterboxd : $($f.title) = $($watchBySlug[$c.slug].Name)"
    $others.Remove($key); $f.exact = $true
    if ($results.Contains($c.slug)) { Merge-Seances $results[$c.slug] $f } else { $results[$c.slug] = $f }
  }
}
$cache.GetEnumerator() | ForEach-Object -Begin { $o = [ordered]@{} } -Process { $o[$_.Key] = $_.Value } -End {
  [IO.File]::WriteAllText($cachePath, ($o | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false))) }
Write-Host "Fiches Letterboxd recherchées : $looked (cache : $($cache.Count))"


# --- 3c. Tes goûts Letterboxd : films vus, notes, et note prévue pour les autres films -------
# 1) Tes films vus avec ta note (en étoiles) et tes coups de cœur.
#    Base : taste-data.json, créé par import-letterboxd.ps1 depuis l'export officiel Letterboxd
#    (les pages qui listent tous tes films sont bloquées par l'anti-robot de Letterboxd).
#    Complément à chaque passage : tes 72 derniers films vus + ton flux RSS (nouvelles notes).
$tastePath = Join-Path (Split-Path $cachePath -Parent) 'taste-data.json'
$tasteData = $null
if (Test-Path $tastePath) { try { $tasteData = Get-Content $tastePath -Raw -Encoding UTF8 | ConvertFrom-Json } catch {} }
$seenFilms = @{}
if ($tasteData -and $tasteData.films) {
  $tasteData.films.PSObject.Properties | ForEach-Object { $seenFilms[$_.Name] = [pscustomobject]@{ r = $_.Value.r; liked = [bool]$_.Value.liked } }
}
$fromExport = $seenFilms.Count
try {
  $html = Get-Utf8 "https://letterboxd.com/$User/films/"
  foreach ($it in (($html -split '<li class="griditem') | Select-Object -Skip 1)) {
    if ($it -notmatch 'data-item-slug="([^"]+)"') { continue }
    $slug = $Matches[1]
    $r = if ($it -match 'rated-(\d+)') { [int]$Matches[1] / 2 } else { $null }
    $old = $seenFilms[$slug]
    $seenFilms[$slug] = [pscustomobject]@{ r = if ($r) { $r } elseif ($old) { $old.r } else { $null }; liked = ($it -match 'icon-liked') -or ($old -and $old.liked) }
  }
} catch { Write-Host "Derniers films vus indisponibles : $_" }
try {
  $rss = Get-Utf8 "https://letterboxd.com/$User/rss/"
  foreach ($item in (($rss -split '<item>') | Select-Object -Skip 1)) {
    if ($item -notmatch '<link>https://letterboxd\.com/[^/]+/film/([^/<]+)/') { continue }
    $slug = $Matches[1]
    $r = if ($item -match '<letterboxd:memberRating>([0-9.]+)<') { [double]$Matches[1] } else { $null }
    $liked = $item -match '<letterboxd:memberLike>Yes<'
    $old = $seenFilms[$slug]
    $seenFilms[$slug] = [pscustomobject]@{ r = if ($r) { $r } elseif ($old) { $old.r } else { $null }; liked = $liked -or ($old -and $old.liked) }
  }
} catch { Write-Host "Flux RSS indisponible : $_" }
# On mémorise (le cache GitHub garde ainsi tes nouvelles notes d'un passage à l'autre)
$fo = [ordered]@{}; foreach ($k in ($seenFilms.Keys | Sort-Object)) { $fo[$k] = $seenFilms[$k] }
$boxdMap = if ($tasteData -and $tasteData.boxd) { $tasteData.boxd } else { [ordered]@{} }
[IO.File]::WriteAllText($tastePath, ([ordered]@{ updated = (Get-Date).ToString('yyyy-MM-dd'); films = $fo; boxd = $boxdMap } | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
Write-Host "Films vus : $($seenFilms.Count) (dont $fromExport depuis l'export ; notés : $(@($seenFilms.Values | Where-Object { $_.r }).Count))"

# 2) Caractéristiques d'un film Letterboxd (cache permanent : une fiche ne change quasiment pas)
$featPath = Join-Path (Split-Path $cachePath -Parent) 'lb-films.json'
$feats = @{}
if (Test-Path $featPath) {
  try { (Get-Content $featPath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $feats[$_.Name] = $_.Value } } catch {}
}
function Get-LbFeatures([string]$slug) {
  if ($feats.ContainsKey($slug)) { return $feats[$slug] }
  try { $p = Get-Utf8 "https://letterboxd.com/film/$slug/" } catch { return $null }
  $o = [ordered]@{ y = 0; avg = $null; g = @(); t = @(); c = @(); d = @(); a = @() }
  if ($p -match 'og:title" content="[^"]*\((\d{4})\)') { $o.y = [int]$Matches[1] }
  if ($p -match '"ratingValue":([0-9.]+)') { $o.avg = [double]$Matches[1] }
  if ($p -match '"genre":\[([^\]]*)\]') { $o.g = @([regex]::Matches($Matches[1], '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) }
  if ($p -match '"countryOfOrigin":\[(.*?)\]') { $o.c = @([regex]::Matches($Matches[1], '"name":"([^"]+)"') | ForEach-Object { $_.Groups[1].Value }) }
  if ($p -match '"director":\[(.*?)\]') { $o.d = @([regex]::Matches($Matches[1], '"name":"([^"]+)"') | ForEach-Object { [regex]::Unescape($_.Groups[1].Value) }) }
  $o.t = @([regex]::Matches($p, 'href="/films/(?:theme|mini-theme)/[^"]+"[^>]*>([^<]+)</a>') | ForEach-Object { [Net.WebUtility]::HtmlDecode($_.Groups[1].Value.Trim()) } | Select-Object -Unique)
  $o.a = @([regex]::Matches($p, 'href="/actor/([^/"]+)/"') | ForEach-Object { $_.Groups[1].Value } | Select-Object -Unique -First 6)
  $feats[$slug] = [pscustomobject]$o
  Start-Sleep -Milliseconds 250
  return $feats[$slug]
}
function Save-Feats {
  $o = [ordered]@{}; foreach ($k in ($feats.Keys | Sort-Object)) { $o[$k] = $feats[$k] }
  [IO.File]::WriteAllText($featPath, ($o | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false)))
}

# 3) Profil : écart de ta note à ta note "attendue", par réalisateur / thème / genre / acteur / pays / décennie
#    (moyenne "rétrécie" vers 0 : une affinité tirée d'un seul film pèse peu)
$Groups = [ordered]@{
  d = @{ w = 1.0;  k = 4.5; label = 'réal.' }
  t = @{ w = 0.9;  k = 9;   label = 'thème' }
  a = @{ w = 0.45; k = 6;   label = 'acteur' }
  g = @{ w = 0.6;  k = 18;  label = 'genre' }
  c = @{ w = 0.3;  k = 18;  label = 'pays' }
  y = @{ w = 0.3;  k = 18;  label = 'décennie' }
}
if ($env:WC_GS) { foreach ($g in @($Groups.Keys)) { $Groups[$g].w *= [double]$env:WC_GS } }   # réglage (tests)
if ($env:WC_KS) { foreach ($g in @($Groups.Keys)) { $Groups[$g].k *= [double]$env:WC_KS } }   # réglage (tests)

function Get-FeatList($ft, [string]$g) {
  if ($g -eq 'y') { if ($ft.y) { return @("$([math]::Floor($ft.y / 10) * 10)") } else { return @() } }
  return @($ft.$g | Where-Object { $_ })
}
$rated = @()
$missing = @($seenFilms.Keys | Where-Object { $seenFilms[$_].r -and -not $feats.ContainsKey($_) })
if ($missing.Count) { Write-Host "Caractéristiques à récupérer pour tes films notés : $($missing.Count)" }
$n = 0
foreach ($slug in $seenFilms.Keys) {
  $s = $seenFilms[$slug]; if (-not $s.r) { continue }
  $ft = Get-LbFeatures $slug; if (-not $ft) { continue }
  $stars = [double]$s.r + $(if ($s.liked) { 0.25 } else { 0 })
  $rated += [pscustomobject]@{ slug = $slug; stars = $stars; ft = $ft }
  if ((++$n % 100) -eq 0) { Save-Feats }
}
Save-Feats
$mu = if ($rated) { ($rated | Measure-Object stars -Average).Average } else { 3 }
$avgVals = @($rated | Where-Object { $_.ft.avg } | ForEach-Object { [double]$_.ft.avg })
$muLb = if ($avgVals) { ($avgVals | Measure-Object -Average).Average } else { 3.5 }
# Ta note "attendue" d'après la note moyenne Letterboxd, ajustée à ta façon de noter (régression linéaire).
# Les affinités ne mesurent ensuite que l'écart à cette attente : ce que tu aimes PLUS ou MOINS que les autres.
$regA = $mu; $regB = 0.0
$withAvg = @($rated | Where-Object { $_.ft.avg })
if ($withAvg.Count -ge 30) {
  $mx = ($withAvg | ForEach-Object { [double]$_.ft.avg } | Measure-Object -Average).Average
  $my = ($withAvg | Measure-Object stars -Average).Average
  $sxy = 0.0; $sxx = 0.0
  foreach ($x in $withAvg) { $dx = [double]$x.ft.avg - $mx; $sxy += $dx * ($x.stars - $my); $sxx += $dx * $dx }
  if ($sxx -gt 0) { $regB = $sxy / $sxx; $regA = $my - $regB * $mx }
}
function Get-Base($ft) { if ($ft.avg) { $regA + $regB * [double]$ft.avg } else { $mu } }

# Ajoute (sign = 1) ou retire (sign = -1) un film du profil
function Update-Profile($prof, $x, [int]$sign) {
  $dev = $x.stars - (Get-Base $x.ft)
  foreach ($g in $Groups.Keys) {
    foreach ($v in (Get-FeatList $x.ft $g)) {
      if (-not $prof[$g].ContainsKey($v)) { $prof[$g][$v] = @(0.0, 0, 0.0) }
      $prof[$g][$v][0] += $sign * $dev; $prof[$g][$v][1] += $sign; $prof[$g][$v][2] += $sign * $x.stars
      if ($prof[$g][$v][1] -le 0) { $prof[$g].Remove($v) }
    }
  }
}
function New-Profile($films) {
  $prof = @{}
  foreach ($g in $Groups.Keys) { $prof[$g] = @{} }
  foreach ($x in $films) { Update-Profile $prof $x 1 }
  $prof
}
# Note prévue + meilleure raison ("Dario Argento : 4 films vus, ★4,3")
function Get-Prediction($ft, $prof) {
  $pred = Get-Base $ft; $best = $null; $bestC = 0
  foreach ($g in $Groups.Keys) {
    $vals = Get-FeatList $ft $g; if (-not $vals) { continue }
    $sum = 0.0
    foreach ($v in $vals) {
      $e = $prof[$g][$v]
      if (-not $e) { continue }
      $aff = $e[0] / ($e[1] + $Groups[$g].k)
      $sum += $aff
      $contrib = $Groups[$g].w * $aff / $vals.Count
      # Explication : seulement réalisateur / thème / genre / acteur (pays et décennie sont trop vagues)
      if ($g -in 'd', 't', 'g', 'a' -and $contrib -gt $bestC -and $e[1] -ge $(if ($g -eq 'd') { 1 } else { 2 })) {
        $bestC = $contrib
        $best = [pscustomobject]@{ g = $g; v = $v; n = $e[1]; avg = [math]::Round($e[2] / $e[1], 1) }
      }
    }
    $pred += $Groups[$g].w * $sum / $vals.Count
  }
  # Qualité (note Letterboxd) : donnée en raison si elle tire nettement le score vers le haut
  $q = if ($ft.avg -and ((Get-Base $ft) - $mu) -gt 0.15) { [math]::Round([double]$ft.avg, 1) } else { $null }
  [pscustomobject]@{ stars = [math]::Max(0.5, [math]::Min(5.0, [double]$pred)); why = $best; q = $q }
}
$taste = New-Profile $rated

# 4) Fiabilité : on cache chaque note une à une (sur un échantillon), on la prédit, on compare
if ($rated.Count -ge 50 -and $env:WC_EVAL) {
  $sample = $rated | Get-Random -Count ([math]::Min(250, $rated.Count)) -SetSeed 42
  $errs = @(); $pairs = @()
  foreach ($x in $sample) {
    Update-Profile $taste $x -1
    $p = Get-Prediction $x.ft $taste
    Update-Profile $taste $x 1
    $errs += [math]::Abs($p.stars - $x.stars); $pairs += , @($p.stars, $x.stars)
  }
  $mx = ($pairs | ForEach-Object { $_[0] } | Measure-Object -Average).Average; $my = ($pairs | ForEach-Object { $_[1] } | Measure-Object -Average).Average
  $cov = 0; $vx = 0; $vy = 0; foreach ($q in $pairs) { $cov += ($q[0] - $mx) * ($q[1] - $my); $vx += ($q[0] - $mx) * ($q[0] - $mx); $vy += ($q[1] - $my) * ($q[1] - $my) }
  $baseline = ($sample | ForEach-Object { [math]::Abs($mu - $_.stars) } | Measure-Object -Average).Average
  Write-Host ("Évaluation : écart moyen {0:N2}★ (sans algo : {1:N2}★), corrélation {2:N2}" -f ($errs | Measure-Object -Average).Average, $baseline, ($cov / [math]::Sqrt($vx * $vy)))
  if ($env:WC_EVALONLY) { exit }
}

# 5) Application aux films hors watchlist
$scored = 0
foreach ($f in $others.Values) {
  $f.seen = $null; $f.match = $null; $f.why = $null
  if (-not $f.slug) { continue }
  if ($seenFilms.ContainsKey($f.slug)) {
    $s = $seenFilms[$f.slug]
    $f.seen = [ordered]@{ r = if ($s.r) { [double]$s.r } else { $null }; liked = [bool]$s.liked }
    continue
  }
  $ft = Get-LbFeatures $f.slug; if (-not $ft) { continue }
  $p = Get-Prediction $ft $taste
  $f.match = [int][math]::Round([math]::Max(1, [math]::Min(99, ($p.stars - 1) / 4 * 100)))
  $f.pred = [math]::Round($p.stars, 1)
  $fr = [Globalization.CultureInfo]'fr-FR'
  $parts = @()
  if ($p.q) { $parts += "Très bien noté sur Letterboxd (★$($p.q.ToString('0.0', $fr)))" }
  if ($p.why) {
    $lab = switch ($p.why.g) {
      'd' { $p.why.v }
      'a' { "avec " + ($fr.TextInfo.ToTitleCase(($p.why.v -replace '-', ' '))) }
      default { $p.why.v }
    }
    $parts += "$lab : $($p.why.n) film$(if ($p.why.n -gt 1) { 's' }) vu$(if ($p.why.n -gt 1) { 's' }), ★$($p.why.avg.ToString('0.0', $fr)) en moyenne"
  }
  if ($parts) { $f.why = $parts -join ' · ' }
  $scored++
}
Save-Feats
Write-Host "Autres films : $(@($others.Values | Where-Object { $_.seen }).Count) déjà vus, $scored avec une note prévue (ta moyenne : ★$([math]::Round($mu, 2)))"

# --- 3b. Films de la watchlist : affiche, note, durée + vérification du réalisateur ----
# Fiches gardées en cache 14 jours (clé "lb:<slug>") : relire chaque fiche à chaque passage prenait l'essentiel du temps
$rejected = @()
foreach ($f in @($results.Values)) {
  # L'affiche est dans les données structurées (JSON-LD) de la fiche Letterboxd ; 3 essais en cas d'erreur réseau
  $lbDirectors = @()
  $fc = $cache["lb:$($f.slug)"]
  $hit = $fc -and $fc.poster -and ($now - [datetime]$fc.t).TotalDays -lt 14
  if ($hit) { $f.poster = $fc.poster; $f.rating = $fc.rating; $f.runtime = $fc.runtime; $lbDirectors = @($fc.dirs) }
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
  if ($hit) { continue }
  if ($f.poster) {
    $cache["lb:$($f.slug)"] = [pscustomobject]@{ poster = $f.poster; rating = $f.rating; runtime = $f.runtime; dirs = @($lbDirectors); t = $now.ToString('yyyy-MM-dd') }
  }
  Start-Sleep -Milliseconds 300
}
$cache.GetEnumerator() | ForEach-Object -Begin { $o = [ordered]@{} } -Process { $o[$_.Key] = $_.Value } -End {
  [IO.File]::WriteAllText($cachePath, ($o | ConvertTo-Json -Depth 4 -Compress), (New-Object Text.UTF8Encoding($false))) }
# Les films écartés (homonymes) rejoignent les "autres films"
foreach ($s in $rejected) {
  $f = $results[$s]; $results.Remove($s)
  $f.slug = $null; $f.poster = $null; $f.rating = $null; $f.runtime = $null
  $rpInfo = Read-RpPage $f
  $f.still = if ($rpInfo.still) { $rpInfo.still } else { Find-WikiImage $f }
  if (-not $others.Contains("rp:$($f.id)")) { $others["rp:$($f.id)"] = $f }
}
Write-Host "Autres films à l'affiche (hors watchlist) : $($others.Count)"

# Film sans image : on reprend celle d'une autre fiche du même titre et du même réalisateur
# (le Rétro Projecteur a parfois 2 fiches pour un même film, ex. "Les Damnés" 1961 / 1962)
function Get-TwinKeys($f) {
  $dir = (Get-Surnames @($f.directors)) -join ','
  $short = ($f.title -split '\s*[:–—(]\s*|\s+-\s+|\s+/\s+', 2)[0]   # "Vivre sa vie: Film en douze tableaux" -> "Vivre sa vie"
  @("$((Get-Words $f.title) -join '')|$dir", "$((Get-Words $short) -join '')|$dir") | Select-Object -Unique
}
$withImg = @{}
foreach ($f in @($results.Values) + @($others.Values)) {
  if ($f.poster -or $f.still) { foreach ($k in (Get-TwinKeys $f)) { $withImg[$k] = $f } }
}
foreach ($f in @($others.Values)) {
  if ($f.poster -or $f.still) { continue }
  $twin = (Get-TwinKeys $f | ForEach-Object { $withImg[$_] } | Where-Object { $_ } | Select-Object -First 1)
  if ($twin) { $f.poster = $twin.poster; $f.still = $twin.still; if (-not $f.slug) { $f.slug = $twin.slug } }
}

# --- 3e. Fiche film : synopsis, sortie, durée, casting (Rétro Projecteur) + Rotten Tomatoes ----------
# Cache permanent film-info.json (clé = id Rétro Projecteur) : une fiche ne change pas. Rotten Tomatoes
# est relu au bout de 30 jours (scores qui bougent pour les nouveautés). Temps limité par passage :
# les fiches manquantes sont complétées aux passages suivants (garde le "tirer pour actualiser" rapide).
$infoPath = Join-Path (Split-Path $cachePath -Parent) 'film-info.json'
$infoCache = @{}
if (Test-Path $infoPath) {
  try { (Get-Content $infoPath -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $infoCache[$_.Name] = $_.Value } } catch {}
}
# Le Rétro Projecteur (Next.js) range les données du film dans des morceaux self.__next_f.push([1,"..."]) :
# on les décode (chaînes JSON) puis on y lit les champs du film.
function Get-RscText([string]$raw) {
  $sb = New-Object Text.StringBuilder
  foreach ($m in [regex]::Matches($raw, 'self\.__next_f\.push\(\[1,"((?:[^"\\]|\\.)*)"\]\)')) {
    try { [void]$sb.Append([string](('"' + $m.Groups[1].Value + '"') | ConvertFrom-Json)) } catch {}
  }
  $sb.ToString()
}
function Get-JsonStr([string]$txt, [string]$name) {
  $m = [regex]::Match($txt, '"' + $name + '":"((?:[^"\\]|\\.)*)"')
  if ($m.Success) { try { return [string](('"' + $m.Groups[1].Value + '"') | ConvertFrom-Json) } catch {} }
  $null
}
function Get-JsonNames([string]$txt, [string]$name) {
  # "actors":"A, B, C"  ou  "actors":["A","B"]  ou  "actors":[{"name":"A"},…]
  $s = Get-JsonStr $txt $name
  if ($s) { return @($s -split '\s*,\s*' | Where-Object { $_ }) }
  $m = [regex]::Match($txt, '"' + $name + '":\[(.*?)\]')
  if (-not $m.Success) { return @() }
  @([regex]::Matches($m.Groups[1].Value, '"(?:name":")?((?:[^"\\]|\\.)+)"') | ForEach-Object { $_.Groups[1].Value } |
    Where-Object { $_ -ne 'name' -and $_ -notmatch '^\d+$' })
}
function Read-RpInfo($f) {
  $o = [ordered]@{ syn = $null; cast = @(); rel = $null; dur = $null; genre = $null }
  try { $raw = Get-Utf8 "https://leretroprojecteur.com/film/$($f.id)" } catch { return $null }
  $txt = Get-RscText $raw
  if (-not $txt) { $txt = $raw -replace '\\"', '"' }
  $o.syn = Get-JsonStr $txt 'overview'
  if (-not $o.syn -and $raw -match '<meta name="description" content="([^"]{60,})"') { $o.syn = [Net.WebUtility]::HtmlDecode($Matches[1]) }
  if ($o.syn) { $o.syn = ($o.syn -replace '\s+', ' ').Trim() }
  $o.cast = @(Get-JsonNames $txt 'actors' | Select-Object -First 5)
  $r = Get-JsonStr $txt 'release_date'; if ($r -match '^(\d{4}-\d{2}-\d{2})') { $o.rel = $Matches[1] }
  $m = [regex]::Match($txt, '"duration":"?(\d+)'); if ($m.Success) { $d = [int]$m.Groups[1].Value; $o.dur = if ($d -gt 400) { [int][math]::Round($d / 60) } else { $d } }
  $g = Get-JsonNames $txt 'genre'; if (-not $g) { $g = Get-JsonNames $txt 'genres' }
  if ($g) { $o.genre = ($g | Select-Object -First 3) -join ', ' }
  [pscustomobject]$o
}
function Get-RtSlug([string]$s) {
  if (-not $s) { return $null }
  $d = $s.Normalize([Text.NormalizationForm]::FormD)
  $sb = New-Object Text.StringBuilder
  foreach ($c in $d.ToCharArray()) { if ([Globalization.CharUnicodeInfo]::GetUnicodeCategory($c) -ne 'NonSpacingMark') { [void]$sb.Append($c) } }
  (($sb.ToString().ToLower() -replace "['’.]", '' -replace '&', 'and' -replace '[^a-z0-9]+', '_').Trim('_'))
}
# Rotten Tomatoes : adresse devinée (titre original, puis slug Letterboxd), année vérifiée à ±1 an
function Find-RottenTomatoes($f) {
  $bases = @((Get-RtSlug $f.original), (Get-RtSlug $f.title)) + @(if ($f.slug) { ($f.slug -replace '-\d{4}$', '') -replace '-', '_' }) |
    Where-Object { $_ -and $_.Length -ge 2 } | Select-Object -Unique
  $tried = @{}
  foreach ($b in $bases) {
    foreach ($c in @(if ($f.year) { "${b}_$($f.year)" }) + @($b)) {
      if ($tried[$c]) { continue }; $tried[$c] = 1
      try { $p = Get-Utf8 "https://www.rottentomatoes.com/m/$c" } catch { Start-Sleep -Milliseconds 150; continue }
      $y = 0
      if ($p -match '"dateCreated":"(\d{4})') { $y = [int]$Matches[1] }
      elseif ($p -match '<title>[^<]*\((\d{4})\)') { $y = [int]$Matches[1] }
      if (-not $f.year -or -not $y -or [math]::Abs($y - [int]$f.year) -gt 1) { continue }
      $o = [ordered]@{ url = "https://www.rottentomatoes.com/m/$c"; c = $null; a = $null; fresh = $false }
      if ($p -match '"aggregateRating":\{[^}]*"ratingValue":"?(\d+)') { $o.c = [int]$Matches[1] }
      if ($p -match '"audienceScore":\{[^}]*"scorePercent":"(\d+)%') { $o.a = [int]$Matches[1] }
      if ($p -match '"criticsScore":\{[^}]*"certified":true') { $o.fresh = $true }
      return [pscustomobject]$o
    }
  }
  $null
}
$infoBudget = [Diagnostics.Stopwatch]::StartNew(); $nInfo = 0; $nRt = 0
foreach ($f in @($results.Values) + @($others.Values)) {
  $k = "$($f.id)"
  $e = $infoCache[$k]
  if ($infoBudget.Elapsed.TotalSeconds -lt 240) {
    if (-not $e -or ($e.v -lt 1 -and ($now - [datetime]$e.t).TotalDays -ge 3)) {
      $rp = Read-RpInfo $f; $nInfo++
      $e = [pscustomobject]@{ v = if ($rp) { 1 } else { 0 }; t = $now.ToString('yyyy-MM-dd'); rp = $rp; rt = $null; rtAt = $null }
      $infoCache[$k] = $e
      Start-Sleep -Milliseconds 200
    }
    if ($f.year -and (-not $e.rtAt -or ($now - [datetime]$e.rtAt).TotalDays -ge 30)) {
      $e.rt = Find-RottenTomatoes $f; $e.rtAt = $now.ToString('yyyy-MM-dd'); $nRt++
    }
  }
  if (-not $e) { continue }
  if ($e.rp) {
    $f.syn = $e.rp.syn; $f.cast = [object[]]@($e.rp.cast); $f.rel = $e.rp.rel; $f.genre = $e.rp.genre
    if (-not $f.runtime -and $e.rp.dur) { $f.runtime = $e.rp.dur }
  }
  if ($e.rt) { $f.rt = $e.rt }
}
$infoCache.GetEnumerator() | ForEach-Object -Begin { $o = [ordered]@{} } -Process { $o[$_.Key] = $_.Value } -End {
  [IO.File]::WriteAllText($infoPath, ($o | ConvertTo-Json -Depth 5 -Compress), (New-Object Text.UTF8Encoding($false))) }
$allF = @($results.Values) + @($others.Values)
$infoMsg = ("Fiches film : {0} lues, {1} Rotten Tomatoes cherchés · synopsis {2}/{3} · RT {4}/{3}" -f $nInfo, $nRt,
  @($allF | Where-Object { $_.syn }).Count, $allF.Count, @($allF | Where-Object { $_.rt }).Count)
Write-Host $infoMsg
if ($env:GITHUB_ACTIONS) { Write-Host "::notice title=Fiches film::$infoMsg" }

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
  title   = if ($films) { "🎬 $($films.Count) film(s) de ta watchlist au ciné cette semaine" } else { 'Rien de ta watchlist au ciné' }
  message = if ($films) { $names } else { "Aucun film de ta watchlist ces $Days prochains jours." }
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
