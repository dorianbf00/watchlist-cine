#!/usr/bin/env bash
# Watchlists Letterboxd des autres utilisateurs de la page (workflow users.yml).
# Les pseudos sont enregistrés par la page auprès du relais Cloudflare ; ici on lit leur watchlist
# (curl passe l'anti-robot de Letterboxd, pas le relais) et on la renvoie au relais, qui la sert à la page.
#   ./users-watchlists.sh            tous les pseudos dont la watchlist a été vérifiée il y a plus de MAX_AGE_H heures
#   ./users-watchlists.sh <pseudo>   ce pseudo seulement (nouvel utilisateur, ou "tirer pour actualiser")
# Variables : RELAY (URL du relais), PUSH_SECRET, MAX_AGE_H (6), BUDGET_S (temps max, 300 s)
set -uo pipefail
RELAY="${RELAY:-https://watchlist-refresh.doriansublon.workers.dev}"
MAX_AGE_H="${MAX_AGE_H:-6}"
BUDGET_S="${BUDGET_S:-300}"
UA='Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130 Safari/537.36'
AUTH="Authorization: Bearer ${PUSH_SECRET:?PUSH_SECRET manquant}"
start=$(date +%s)

if [ -n "${1:-}" ]; then
  users="$1"
else
  # Les plus anciennes d'abord (jamais vérifiées en tête)
  limit=$(( $(date +%s) - MAX_AGE_H * 3600 ))
  users=$(curl -sSf -H "$AUTH" "$RELAY/users" | jq -r --argjson lim "$limit" '
    .users | map(select(.checked == null or (.checked | sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601) < $lim))
    | sort_by(.checked // "") | .[].user') || { echo "::error::Relais injoignable"; exit 1; }
fi
[ -z "$users" ] && { echo "Aucune watchlist à rafraîchir"; exit 0; }

done_n=0; fails=0
for u in $users; do
  if [ $(( $(date +%s) - start )) -gt "$BUDGET_S" ]; then echo "Temps écoulé : la suite au prochain passage"; break; fi
  [[ "$u" =~ ^[a-z0-9_]{2,30}$ ]] || continue
  slugs=""; page=1; status=ok
  while [ $page -le 100 ]; do
    code=$(curl -s -A "$UA" -o page.html -w '%{http_code}' "https://letterboxd.com/$u/watchlist/page/$page/")
    if [ "$code" = 404 ] && [ $page = 1 ]; then status=notfound; break; fi
    if [ "$code" != 200 ]; then [ $page = 1 ] && status="erreur $code"; [ $page -gt 1 ] && status="erreur $code (page $page)"; break; fi
    found=$(grep -oE 'data-item-name="[^"]+"[^>]*data-item-slug="[^"]+"' page.html | sed -E 's/.*data-item-slug="([^"]+)"/\1/')
    [ -z "$found" ] && break
    slugs+="$found"$'\n'
    page=$((page + 1))
    sleep 0.4
  done
  if [ "$status" = notfound ]; then
    echo "$u : pseudo introuvable"
    curl -sS -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "{\"user\":\"$u\",\"error\":\"notfound\"}" "$RELAY/wl" > /dev/null
  elif [ "$status" != ok ]; then
    # Blocage ou panne Letterboxd : on garde l'ancienne watchlist, on réessaiera au prochain passage
    echo "::warning::$u : Letterboxd $status"
    fails=$((fails + 1)); [ $fails -ge 3 ] && { echo "::warning::Letterboxd bloque : arrêt"; break; }
    continue
  else
    body=$(printf '%s' "$slugs" | jq -R . | jq -sc --arg u "$u" '{user: $u, slugs: map(select(length > 0))}')
    echo "$u : $(curl -sS -X POST -H "$AUTH" -H 'Content-Type: application/json' -d "$body" "$RELAY/wl")"
    fails=0
  fi
  done_n=$((done_n + 1))
  sleep 1
done
echo "Watchlists traitées : $done_n en $(( $(date +%s) - start )) s"
