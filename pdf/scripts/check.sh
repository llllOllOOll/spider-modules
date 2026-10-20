#!/usr/bin/env bash
# Writes the sample document (pdf/examples/sample.zig) and checks it with
# tools that read PDFs the way readers do: qpdf (structure, xref, streams),
# pdftotext (the text comes back, accents included) and pdffonts (an
# embedded font is a subset with a Unicode map). Needs qpdf and
# poppler-utils. The embedded font is PDF_FONT, or Noto Sans when it is
# installed; without either, that page is skipped.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
font=${PDF_FONT:-/usr/share/fonts/noto/NotoSans-Regular.ttf}
if [ -f "$font" ]; then
  zig build pdf-sample -Dpdf-font="$font"
else
  echo "note: no TrueType font at $font (set PDF_FONT): the embedded-font page is skipped"
  font=""
  zig build pdf-sample
fi
out=zig-out/pdf-sample.pdf

qpdf --check "$out"
text=$(pdftotext "$out" -)
for want in "Invoice 2026-0042" "José Antônio da Conceição" "€" "Page 3 of " "A landscape page"; do
  if ! grep -qF "$want" <<<"$text"; then
    echo "error: \"$want\" missing from the text of $out" >&2
    exit 1
  fi
done
if [ -n "$font" ]; then
  if ! pdffonts "$out" | grep -E "CID TrueType +Identity-H +yes +yes +yes" >/dev/null; then
    echo "error: the embedded font is not an embedded subset with a Unicode map:" >&2
    pdffonts "$out" >&2
    exit 1
  fi
  for want in "Съешь же ещё" "Ξεσκεπάζω" "Zażółć gęślą jaźń"; do
    if ! grep -qF "$want" <<<"$text"; then
      echo "error: \"$want\" (embedded font) missing from the text of $out" >&2
      exit 1
    fi
  done
fi
echo "ok: $out passes qpdf and its text reads back"
