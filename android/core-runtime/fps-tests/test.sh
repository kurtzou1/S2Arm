#!/bin/bash
# 门禁覆盖：android/core-runtime/AndroidPresentCounter.cs android/core-runtime/AndroidGameRuntime.cs android/app/src/main/java/org/s2arm/android/FrameRate*.java
set -euo pipefail
R=$(cd "$(dirname "$0")/../../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_CLI_WORKLOAD_UPDATE_NOTIFY_DISABLE=1
# This source-only project has no package dependencies. Never consult network feeds,
# and keep both restore and build outputs private to this invocation.
printf '%s\n' '<configuration><packageSources><clear /></packageSources></configuration>' > "$T/nuget.config"
project="$R/android/core-runtime/fps-tests/FpsTests.csproj"
dotnet restore "$project" --configfile "$T/nuget.config" --verbosity quiet \
    --artifacts-path "$T/artifacts" -p:NuGetAudit=false
dotnet build "$project" --no-restore --disable-build-servers --verbosity quiet \
    --artifacts-path "$T/artifacts"
dotnet "$T/artifacts/bin/FpsTests/debug/FpsTests.dll"
"${S2A_PY:-python3}" "$R/android/core-runtime/fps-tests/present-source-test.py" --dotnet "$(command -v dotnet)" --output "$T/present-source"
javac -d "$T" "$R/android/app/src/main/java/org/s2arm/android/FrameRateSample.java" "$R/android/core-runtime/fps-tests/FrameRateSampleTest.java"
java -cp "$T" org.s2arm.android.FrameRateSampleTest
