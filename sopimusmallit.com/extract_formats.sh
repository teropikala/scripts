#!/usr/bin/env bash
set -u

#
# Make a local copy of the site pages with something like this (c. 12 minutes; add wait time if not in a hurry)
#
# wget --recursive --level=5 --wait=2 --no-parent --domains=sopimusmallit.com --reject=jpg,jpeg,png,gif,webp,svg,ico,bmp,tif,tiff https://www.sopimusmallit.com/
#
# and run the tool like this: 
#
# DEBUG=1 bash extract_formats.sh www.sopimusmallit.com output.csv 
#
#
# Generate status in Google Sheets with this: 
# 
# =LET(
#  fmts, TOCOL(C2:F2, 1),
#  hasDOCX, COUNTIF(fmts,"DOCX")>0,
#  hasDOC,  COUNTIF(fmts,"DOC")>0,
#  IF(hasDOCX,
#     IF(hasDOC,"Easy fix","OK"),
#     "Conversion"
#  )
# )


ROOT="${1:-.}"
OUT="${2:-formats.csv}"
DEBUG="${DEBUG:-1}"

log() { [[ "$DEBUG" == "1" ]] && printf '[debug] %s\n' "$*" >&2; }

PROD_DIR="$ROOT/product"
[[ -d "$PROD_DIR" ]] || { echo "ERROR: product dir not found: $PROD_DIR" >&2; exit 1; }

ALLOW_RE='DOCX|DOC|RTF|ODT'

# Minimal HTML entity decode for Finnish umlauts (and a few common ones)
decode_entities() {
  sed -e 's/&auml;/ä/g; s/&Auml;/Ä/g' \
      -e 's/&ouml;/ö/g; s/&Ouml;/Ö/g' \
      -e 's/&aring;/å/g; s/&Aring;/Å/g' \
      -e 's/&uuml;/ü/g; s/&Uuml;/Ü/g' \
      -e 's/&eacute;/é/g; s/&Eacute;/É/g' \
      -e 's/&amp;/\&/g; s/&quot;/"/g; s/&#39;/'\''/g' \
      -e 's/&nbsp;/ /g'
}

tmp="$(mktemp)"
trap 'rm -f "$tmp"' EXIT

log "Scanning: $PROD_DIR"
log "Writing:  $OUT"

find "$PROD_DIR" -type f -print0 2>/dev/null |
  xargs -0 grep -Il 'BuyFormVariationRadio' |
  while IFS= read -r f; do
    log "Processing: $f"

    # product id from path: .../product/{id}/...
    if [[ "$f" =~ /product/([0-9]+)/ ]]; then
      pid="${BASH_REMATCH[1]}"
    else
      log "  Skip (no /product/{id}/ in path)"
      continue
    fi

    # product title from HTML: <h1 class="Title">...</h1>
    title="$(
      grep -aom1 -E '<h1[^>]*class="Title"[^>]*>.*</h1>' "$f" 2>/dev/null \
        | sed -E 's/.*class="Title"[^>]*>//; s#</h1>.*##' \
        | sed -E 's/<[^>]+>//g' \
        | decode_entities \
        | sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
    )"

    # fallback to slug if title not found
    if [[ -z "${title}" ]]; then
      if [[ "$f" =~ /product/[0-9]+/([^/]+)($|/) ]]; then
        title="${BASH_REMATCH[1]}"
        log "  Title not found in HTML; falling back to slug: $title"
      else
        log "  Title not found and no slug; skipping"
        continue
      fi
    fi

    log "  Product: id=$pid title=$title"

	# Extract allowed formats from inside (...) even if dash is encoded (&ndash;)
	formats="$(
	  { grep -aioE '\([^)]*\)' "$f" || true; } \
	    | tr '[:lower:]' '[:upper:]' \
	    | grep -oE '(DOCX|ODT|RTF|DOC)([^A-Z0-9]|$)' \
	    | sed -E 's/[^A-Z0-9].*$//' \
	    | awk '!seen[$0]++' \
	    | paste -sd, -
	)"
	
	log " formats ${formats}"
	
    if [[ -z "${formats}" ]]; then
      log "  No allowed formats found; skipping."
      continue
    fi

    log "  Formats: $formats"
    printf '%s,%s,%s\n' "$pid" "$title" "$formats" >> "$tmp"
  done

# De-dupe by product id (keep first), sort by id
awk -F, '!seen[$1]++' "$tmp" | sort -t, -k1,1n > "$OUT"

log "Final rows: $(wc -l < "$OUT" | tr -d ' ')"
echo "Wrote: $OUT"