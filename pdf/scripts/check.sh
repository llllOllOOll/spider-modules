#!/usr/bin/env bash
# Writes the sample document (pdf/examples/sample.zig) and checks it with
# tools that read PDFs the way readers do: qpdf (structure, xref, streams)
# and pdftotext (the text comes back, accents included). Needs qpdf and
# poppler-utils.
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
cd "$ROOT"
zig build pdf-sample
out=zig-out/pdf-sample.pdf

qpdf --check "$out"
text=$(pdftotext "$out" -)
for want in "Invoice 2026-0042" "José Antônio da Conceição" "€" "Page 3 of 3" "A landscape page"; do
  if ! grep -qF "$want" <<<"$text"; then
    echo "error: \"$want\" missing from the text of $out" >&2
    exit 1
  fi
done
echo "ok: $out passes qpdf and its text reads back"
