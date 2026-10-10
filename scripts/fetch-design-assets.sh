#!/usr/bin/env bash
# Downloads the open-licensed design assets used by the Flow design system.
# Fonts: Google Fonts GitHub repo (SIL OFL). Icons: lucide-static (ISC).
# Nothing here is taken from any other app bundle.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FONTS="$ROOT/FreeFlow/Resources/Fonts"
ICONS="$ROOT/FreeFlow/Resources/Icons"
mkdir -p "$FONTS" "$ICONS"

GF="https://raw.githubusercontent.com/google/fonts/main/ofl"
LUCIDE_VERSION="0.469.0"
LUCIDE="https://unpkg.com/lucide-static@${LUCIDE_VERSION}/icons"

missing=()

fetch() { # url dest
    local url="$1" dest="$2"
    if curl -fsSL --retry 2 -o "$dest.part" "$url"; then
        mv "$dest.part" "$dest"
        return 0
    fi
    rm -f "$dest.part"
    return 1
}

fetch_font() { # url dest
    local url="$1" dest="$2"
    if [ -s "$dest" ] && file "$dest" | grep -qi "TrueType"; then
        echo "ok (cached)  $(basename "$dest")"; return
    fi
    if fetch "$url" "$dest" && file "$dest" | grep -qi "TrueType"; then
        echo "ok           $(basename "$dest")"
    else
        rm -f "$dest"
        missing+=("$(basename "$dest")")
        echo "MISSING      $(basename "$dest")"
    fi
}

fetch_text() { # url dest
    local url="$1" dest="$2"
    if fetch "$url" "$dest" && [ -s "$dest" ]; then
        echo "ok           $(basename "$dest")"
    else
        rm -f "$dest"
        missing+=("$(basename "$dest")")
        echo "MISSING      $(basename "$dest")"
    fi
}

echo "== Fonts"
fetch_font "$GF/figtree/Figtree%5Bwght%5D.ttf"                    "$FONTS/Figtree-Variable.ttf"
fetch_font "$GF/figtree/Figtree-Italic%5Bwght%5D.ttf"             "$FONTS/Figtree-Italic-Variable.ttf"
fetch_font "$GF/ebgaramond/EBGaramond%5Bwght%5D.ttf"              "$FONTS/EBGaramond-Variable.ttf"
fetch_font "$GF/ebgaramond/EBGaramond-Italic%5Bwght%5D.ttf"       "$FONTS/EBGaramond-Italic-Variable.ttf"
fetch_font "$GF/googlesanscode/GoogleSansCode%5Bwght%5D.ttf"      "$FONTS/GoogleSansCode-Variable.ttf"
fetch_text "$GF/figtree/OFL.txt"         "$FONTS/Figtree-OFL.txt"
fetch_text "$GF/ebgaramond/OFL.txt"      "$FONTS/EBGaramond-OFL.txt"
fetch_text "$GF/googlesanscode/OFL.txt"  "$FONTS/GoogleSansCode-OFL.txt"

echo "== Icons (lucide-static@${LUCIDE_VERSION})"
ICON_NAMES=(
  mic chart-column-big book-text file-volume settings panel-left
  search arrow-up-down refresh-cw plus x check copy play pause ellipsis-vertical
  rotate-cw trash info circle-alert star pencil sparkles external-link arrow-right
  arrow-up-right undo-2 loader-circle circle-check
  trending-up trending-down tv-minimal infinity bot file-text mail
  message-circle-more message-square-text chevron-left chevron-right chevron-down
  share trophy flame
  sliders-horizontal laptop monitor shield-check sun moon download upload file-up
  folder keyboard languages headphones volume-2 lock terminal brain lightbulb
  pen-line users compass
)

# Older or newer lucide names to try when a name 404s in this version.
alias_for() {
  case "$1" in
    file-volume) echo "file-audio file-music" ;;
    circle-question-mark) echo "circle-help help-circle" ;;
    chart-column-big) echo "bar-chart-big bar-chart-3" ;;
    loader-circle) echo "loader-2" ;;
    circle-alert) echo "alert-circle" ;;
    circle-check) echo "check-circle check-circle-2" ;;
    ellipsis-vertical) echo "more-vertical" ;;
    tv-minimal) echo "tv-2 tv" ;;
    message-circle-more) echo "message-circle" ;;
    message-square-text) echo "message-square" ;;
    sliders-horizontal) echo "sliders" ;;
    pen-line) echo "edit-3" ;;
    undo-2) echo "undo" ;;
    trash) echo "trash-2" ;;
    *) echo "" ;;
  esac
}

for name in "${ICON_NAMES[@]}"; do
  dest="$ICONS/lucide-$name.svg"
  if [ -s "$dest" ]; then echo "ok (cached)  lucide-$name.svg"; continue; fi
  if fetch "$LUCIDE/$name.svg" "$dest" && grep -q "<svg" "$dest"; then
    echo "ok           lucide-$name.svg"; continue
  fi
  rm -f "$dest"
  got=""
  for alt in $(alias_for "$name"); do
    if fetch "$LUCIDE/$alt.svg" "$dest" && grep -q "<svg" "$dest"; then
      got="$alt"; break
    fi
    rm -f "$dest"
  done
  if [ -n "$got" ]; then
    echo "ok (alias)   lucide-$name.svg <- $got"
  else
    missing+=("lucide-$name.svg")
    echo "MISSING      lucide-$name.svg"
  fi
done

fetch_text "https://unpkg.com/lucide-static@${LUCIDE_VERSION}/LICENSE" "$ICONS/lucide-LICENSE.txt"

echo
if [ ${#missing[@]} -eq 0 ]; then
  echo "All design assets present."
else
  echo "Missing (${#missing[@]}):"
  for m in "${missing[@]}"; do echo "  - $m"; done
  exit 1
fi
