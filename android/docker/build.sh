#!/usr/bin/env bash
# Build only: this container receives no device, USB, adb, or host-network access.
set -euo pipefail
android_dir=$(cd "$(dirname "$0")/.." && pwd)
repo_dir=$(cd "$android_dir/.." && pwd)
image=${S2ARM_ANDROID_IMAGE:-s2arm-android-build:1}
cache=${S2ARM_ANDROID_CACHE:-s2arm-android-build-cache}
. "$android_dir/tools/versions.sh"
if ! docker image inspect "$image" > /dev/null 2>&1; then
    echo "Missing image $image. Build it with:" >&2
    printf '  docker build -t %q %q\n' "$image" "$android_dir/docker" >&2
    exit 1
fi
args=(--rm --user "$(id -u):$(id -g)"
    --env "S2A_ANDROID_BUILD_TOOLS=$S2A_ANDROID_BUILD_TOOLS"
    --mount "type=bind,source=$repo_dir,target=/src"
    --mount "type=volume,source=$cache,target=/cache"
    --env 'HOME=/cache/home' --env 'S2A_BUILD_CACHE=/cache' --env 'GRADLE_USER_HOME=/cache/gradle'
    --env 'ANDROID_USER_HOME=/cache/android-user'
    --env "S2ARM_ANDROID_CS_SERVICES=${S2ARM_ANDROID_CS_SERVICES:-0}"
    --env "S2ARM_ANDROID_GAME_DIR=${S2ARM_ANDROID_GAME_DIR:-}"   # per-game APK: tools/game_apk.py output, repo-relative
    --env "S2ARM_ANDROID_VK_ENGINE=${S2ARM_ANDROID_VK_ENGINE:-0}"
    --env "S2ARM_ANDROID_VK_BACKEND=${S2ARM_ANDROID_VK_BACKEND:-nvk}"
    --workdir /src/android --entrypoint bash)
if [ "${1:-}" = --direct-identity ]; then   # 只出 build/android-direct/identity.json（安卓出包器用）
    # shellcheck disable=SC2016
    exec docker run "${args[@]}" "$image" -c 'mkdir -p "$HOME" && exec bash cs/build.sh --direct-identity'
fi
if [ $# -eq 0 ]; then
    # shellcheck disable=SC2016
    exec docker run "${args[@]}" "$image" -c '
        set -euo pipefail
        mkdir -p "$HOME" "$GRADLE_USER_HOME" "$ANDROID_USER_HOME"
        bash cs/build.sh
        bash openssl/build.sh
        gradle --no-daemon --project-cache-dir /src/build/android-gradle-project :app:assembleDebug :app:lintDebug
        python3 verify-apk.py app/build/outputs/apk/debug/app-debug.apk
        "$ANDROID_HOME/build-tools/$S2A_ANDROID_BUILD_TOOLS/apksigner" verify app/build/outputs/apk/debug/app-debug.apk
    '
fi
# Explicit Gradle tasks (for example --offline :app:assembleDebug). No deployment commands.
# shellcheck disable=SC2016
exec docker run "${args[@]}" "$image" -c \
    'mkdir -p "$HOME" "$GRADLE_USER_HOME" "$ANDROID_USER_HOME" && exec gradle --no-daemon --project-cache-dir /src/build/android-gradle-project "$@"' _ "$@"

