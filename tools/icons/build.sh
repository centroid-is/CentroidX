#!/usr/bin/env bash
# Rebuild assets/fonts/TfcIcons.ttf from the glyph sources in this directory.
#
# The font is checked in, so this only has to run when a glyph changes. It
# rebuilds from a pristine copy of the Fontello original (TfcIcons.base.ttf) so
# that re-running it is idempotent rather than merging on top of a merge.
set -euo pipefail

cd "$(dirname "$0")/../.."
VENV=".dart_tool/icon-venv"

if [[ ! -x "$VENV/bin/python" ]]; then
  echo "creating $VENV"
  python3 -m venv "$VENV"
  "$VENV/bin/pip" install --quiet --upgrade pip
  "$VENV/bin/pip" install --quiet fonttools skia-pathops pillow
fi

cp tools/icons/TfcIcons.base.ttf assets/fonts/TfcIcons.ttf
"$VENV/bin/python" tools/icons/industrial_icons.py \
  assets/fonts/TfcIcons.ttf lib/converter/industrial_icons.dart
"$VENV/bin/python" tools/icons/proof_sheet.py \
  assets/fonts/TfcIcons.ttf tools/icons/proof_sheet.png

echo
echo "Now eyeball tools/icons/proof_sheet.png before committing."
