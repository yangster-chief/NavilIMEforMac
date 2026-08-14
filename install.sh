#!/bin/bash
#
# 빌드한 NavilIME.app 을 ~/Library/Input Methods 에 설치한다.
#
# 사용법:
#   ./install.sh              # Release 산출물을 찾아 설치 (직접 빌드해 둔 것)
#   ./install.sh --build      # Release 로 빌드부터 하고 설치
#   ./install.sh <경로>       # 지정한 .app 을 설치
#
# 주의: 기존 설치본은 새 산출물의 존재를 확인한 뒤에만 지운다.
#       (예전 버전은 먼저 지우고 복사에 실패하면 입력기가 사라졌다)

set -euo pipefail

PROJECT="NavilIME.xcodeproj"
SCHEME="NavilIME"
CONFIG="Release"
DEST="$HOME/Library/Input Methods"

cd "$(dirname "$0")"

APP=""
case "${1-}" in
    --build)
        echo "==> ${CONFIG} 빌드"
        xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" build
        ;;
    "")
        ;;
    *)
        APP="$1"
        ;;
esac

# 경로를 직접 주지 않았으면 xcodebuild 에게 산출물 위치를 물어본다.
# (DerivedData 경로는 프로젝트마다 해시가 달라 하드코딩할 수 없다)
if [ -z "$APP" ]; then
    BUILT_DIR=$(xcodebuild -project "$PROJECT" -scheme "$SCHEME" -configuration "$CONFIG" \
        -showBuildSettings 2>/dev/null \
        | awk -F' = ' '/ BUILT_PRODUCTS_DIR = /{print $2; exit}')
    APP="$BUILT_DIR/NavilIME.app"
fi

if [ ! -d "$APP" ]; then
    echo "오류: 설치할 앱을 찾을 수 없습니다 — $APP" >&2
    echo "      먼저 빌드하거나 './install.sh --build' 를 쓰세요." >&2
    exit 1
fi

echo "==> 설치할 앱: $APP"

# 개인 서명 설정이 번들에 섞여 들어갔으면 알린다. (Team ID 가 배포본에 남는다)
if [ -e "$APP/Contents/Resources/Local.xcconfig" ]; then
    echo "경고: 번들에 Local.xcconfig 가 들어 있습니다. 개인 Team ID 가 노출됩니다." >&2
    echo "      Xcode 프로젝트의 Copy Bundle Resources 에서 빼세요." >&2
fi

# 실행 중인 입력기를 먼저 내린다. 안 그러면 옛 프로세스가 그대로 살아 있어
# 새 Info.plist(입력 모드 등)를 읽지 않는다.
if pgrep -f "Input Methods/NavilIME.app" > /dev/null; then
    echo "==> 실행 중인 NavilIME 종료"
    pkill -f "Input Methods/NavilIME.app" || true
    sleep 1
fi

echo "==> 기존 설치본 제거"
rm -rf "$DEST/NavilIME.app"

echo "==> 복사"
mkdir -p "$DEST"
cp -R "$APP" "$DEST/"

echo "==> 완료"
ls -d "$DEST/NavilIME.app"

cat <<'EOF'

입력 모드 구성이 바뀐 빌드라면 다음도 필요합니다:
  1. 시스템 설정 > 키보드 > 입력 소스에서 NavilIME 제거
  2. 로그아웃 → 로그인
  3. 입력 소스에서 "나빌입력기" / "나빌입력기 (영문)" 추가
EOF
