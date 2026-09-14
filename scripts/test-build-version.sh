#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"; SCRIPT="$ROOT/scripts/build-app.sh"; T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin" "$T/src/scripts" "$T/src/Sources/截图Free/Resources" "$T/src/Xcode"; printf 'x' > "$T/src/Sources/截图Free/Resources/AppIcon.icns"; printf 'x' > "$T/src/Xcode/截图Free.entitlements"; printf '说明\n' > "$T/notes.md"
printf '// mock package\n' > "$T/src/Package.swift"
printf ' \t\n\r\n' > "$T/blank-notes.md"
export MOCK_SIGN_FAIL=0
export MOCK_CALLS="$T/mock-calls.log"
: > "$MOCK_CALLS"
cp "$SCRIPT" "$T/src/scripts/build-app.sh"; chmod +x "$T/src/scripts/build-app.sh"
cat > "$T/bin/swift" <<'EOF'
#!/bin/sh
printf 'swift\n' >> "$MOCK_CALLS"
mkdir -p .build/debug; printf '#!/bin/sh\n' > .build/debug/截图Free; chmod +x .build/debug/截图Free
EOF
chmod +x "$T/bin/swift"
cat > "$T/bin/ditto" <<'EOF'
#!/bin/sh
printf 'ditto\n' >> "$MOCK_CALLS"
touch "$6"
EOF
chmod +x "$T/bin/ditto"
cat > "$T/bin/plutil" <<'EOF'
#!/bin/sh
printf 'plutil\n' >> "$MOCK_CALLS"
grep -q 'CFBundleShortVersionString' "$2"
EOF
chmod +x "$T/bin/plutil"
cat > "$T/bin/codesign" <<'EOF'
#!/bin/sh
printf 'codesign %s\n' "$1" >> "$MOCK_CALLS"
case "$MOCK_SIGN_FAIL:$1" in 1:--force|verify:--verify) exit 1;; esac
exit 0
EOF
chmod +x "$T/bin/codesign"
cat > "$T/bin/security" <<'EOF'
#!/bin/sh
exit 1
EOF
chmod +x "$T/bin/security"
expect_failure() {
  local expected="$1" status=0
  shift
  PATH="$T/bin:$PATH" bash "$T/src/scripts/build-app.sh" "$@" > "$T/failure.log" 2>&1 || status=$?
  if [[ "$status" != "$expected" ]]; then
    printf '预期退出码 %s，实际 %s\n' "$expected" "$status" >&2
    cat "$T/failure.log" >&2
    exit 1
  fi
}
expect_failure 2 debug
expect_failure 2 debug "$T/blank-notes.md"
test ! -s "$MOCK_CALLS"
test ! -e "$T/src/version-state"
test ! -e "$T/src/CHANGELOG.md"
test ! -e "$T/src/dist"
PATH="$T/bin:$PATH" bash "$T/src/scripts/build-app.sh" debug "$T/notes.md" >/dev/null
test -f "$T/src/dist/截图Free-v1.0.1-build2.zip"
grep -qx '## v1.0.1-build2' "$T/src/CHANGELOG.md"
grep -qx '说明' "$T/src/dist/截图Free-v1.0.1-build2.md"
printf 'VERSION=1.0.1\nBUILD=2\n' > "$T/expected-state"
cmp "$T/expected-state" "$T/src/version-state"
PATH="$T/bin:$PATH" bash "$T/src/scripts/build-app.sh" debug "$T/notes.md" >/dev/null
test -f "$T/src/dist/截图Free-v1.0.2-build3.zip"
grep -qx '说明' "$T/src/dist/截图Free-v1.0.2-build3.md"
printf 'VERSION=1.0.2\nBUILD=3\n' > "$T/expected-state"
cmp "$T/expected-state" "$T/src/version-state"
test "$(grep -c '^## v' "$T/src/CHANGELOG.md")" -eq 2
grep -qx '## v1.0.2-build3' "$T/src/CHANGELOG.md"
printf 'swift\ncodesign --force\nplutil\ncodesign --verify\nditto\nswift\ncodesign --force\nplutil\ncodesign --verify\nditto\n' > "$T/expected-calls"
cmp "$T/expected-calls" "$MOCK_CALLS"
cp "$T/src/CHANGELOG.md" "$T/changelog-before"
cp -R "$T/src/dist" "$T/dist-before"
for failure in 1 verify; do
  : > "$MOCK_CALLS"
  MOCK_SIGN_FAIL="$failure" expect_failure 1 debug "$T/notes.md"
  cmp "$T/expected-state" "$T/src/version-state"
  cmp "$T/changelog-before" "$T/src/CHANGELOG.md"
  diff -r "$T/dist-before" "$T/src/dist"
  test ! -e "$T/src/dist/截图Free-v1.0.3-build4.zip"
  test ! -e "$T/src/dist/截图Free-v1.0.3-build4.md"
  test ! -e "$T/src/.build/build.lock"
  if [[ "$failure" == 1 ]]; then
    printf 'swift\ncodesign --force\n' > "$T/expected-calls"
  else
    printf 'swift\ncodesign --force\nplutil\ncodesign --verify\n' > "$T/expected-calls"
  fi
  cmp "$T/expected-calls" "$MOCK_CALLS"
done
printf '%s\n' 'mock 测试通过：缺少/空白说明、两次成功递增、签名及签名验证失败不推进版本且保留历史产物'
