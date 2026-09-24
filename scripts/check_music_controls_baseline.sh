#!/bin/bash
# Prove two unchanged control regressions against the audited revision using
# actual Swift/XCTest. Uses a temporary checkout; never touches the working app.
set -euo pipefail
repo_root=$(git rev-parse --show-toplevel)
comparison_dir=$(mktemp -d)
trap 'rm -rf "$comparison_dir"' EXIT
baseline=3ceeec29d88a9193be5c3402779a376a27b07e59
git -C "$repo_root" archive "$baseline" | tar -x -C "$comparison_dir"
python3 - "$repo_root" "$comparison_dir" <<'PY'
from pathlib import Path
import sys
current=Path(sys.argv[1], 'LumenDeskTests/MusicModeTests.swift').read_text()
methods=current[current.index('    func testMasterZeroAndLiveCeilingIncludeFlashes'):current.index('    func testPaletteDoesNotJumpWhenTempoIsReacquired')]
p=Path(sys.argv[2], 'LumenDeskTests/MusicModeTests.swift')
p.write_text(p.read_text().replace('final class MusicModeTests: XCTestCase {','final class MusicModeTests: XCTestCase {\n'+methods))
PY
cd "$comparison_dir"
set +e
xcodebuild -project LumenDesk.xcodeproj -scheme LumenDesk -configuration Debug \
  -destination 'platform=macOS' -parallel-testing-enabled NO \
  -derivedDataPath "$comparison_dir/DerivedData" \
  -only-testing:LumenDeskTests/MusicModeTests/testMasterZeroAndLiveCeilingIncludeFlashes \
  -only-testing:LumenDeskTests/MusicModeTests/testEveryRolePreservesSingleColorThemeAndZeroHoldsPalette \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test > "$comparison_dir/baseline.log" 2>&1
result=$?
set -e
# A build failure is NOT the expected regression failure. Both tests must run.
if [[ $result -eq 0 ]] || ! grep -q 'XCTAssert.*failed' "$comparison_dir/baseline.log"; then
  cat "$comparison_dir/baseline.log"
  exit 1
fi
for name in testMasterZeroAndLiveCeilingIncludeFlashes testEveryRolePreservesSingleColorThemeAndZeroHoldsPalette; do
  if ! grep "$name.*failed" "$comparison_dir/baseline.log" >/dev/null; then
    cat "$comparison_dir/baseline.log"
    exit 1
  fi
done
grep -E 'Test Case.*failed|Executed.*tests|TEST FAILED' "$comparison_dir/baseline.log"
echo 'EXPECTED BASELINE FAILURE: both unchanged Swift control regressions failed at 3ceeec2.'
