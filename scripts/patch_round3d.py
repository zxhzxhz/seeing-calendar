#!/usr/bin/env python3
"""Round-3 patch D: pulse identity plumbing + version injection."""
from __future__ import annotations

import pathlib

ROOT = pathlib.Path(__file__).resolve().parents[1]


def patch(rel: str, pairs: list[tuple[str, str]]) -> None:
    path = ROOT / rel
    text = path.read_text(encoding="utf-8")
    for old, new in pairs:
        if old not in text:
            raise SystemExit(f"MISS in {rel}: {old[:90]!r}")
        text = text.replace(old, new, 1)
    path.write_text(text, encoding="utf-8")
    print("patched", rel)


patch(
    "SeeingCalendar/Views/DayCellView.swift",
    [
        (
            """    let isSelected: Bool
    let isPulsing: Bool
    let tier: CellLODTier""",
            """    let isSelected: Bool
    let isPulsing: Bool
    /// 脉冲代次：每次「今天」定位都递增，保证动画可重复触发。
    let pulseID: Int
    let tier: CellLODTier""",
        ),
        (
            """                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .scaleEffect(1 + 0.45 * pulseProgress)
                        .opacity(Double(1 - pulseProgress))
                        .onAppear {""",
            """                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(Color.accentColor, lineWidth: 3)
                        .scaleEffect(1 + 0.45 * pulseProgress)
                        .opacity(Double(1 - pulseProgress))
                        .id(pulseID)
                        .onAppear {""",
        ),
    ],
)

patch(
    "SeeingCalendar/Views/MonthGridView.swift",
    [
        (
            """    /// 「今天」定位脉冲高亮的日期键。
    let pulseKey: String?""",
            """    /// 「今天」定位脉冲高亮的日期键与代次。
    let pulseKey: String?
    let pulseID: Int""",
        ),
        (
            """                           isPulsing: pulseKey == key,
                           tier: tier)""",
            """                           isPulsing: pulseKey == key,
                           pulseID: pulseID,
                           tier: tier)""",
        ),
    ],
)

patch(
    "SeeingCalendar/Views/RootView.swift",
    [
        (
            """                             pulseKey: pulseKey,
                             zoomNamespace: zoomNamespace,""",
            """                             pulseKey: pulseKey,
                             pulseID: pulseToken,
                             zoomNamespace: zoomNamespace,""",
        ),
    ],
)

# 版本号注入：MARKETING_VERSION 写死在 project.yml，BUILD 号由 CI 的 run number 注入
patch(
    "project.yml",
    [
        (
            """settings:
  base:
    SWIFT_VERSION: "6.0\"""",
            """settings:
  base:
    MARKETING_VERSION: "1.0.1"
    CURRENT_PROJECT_VERSION: "1"
    SWIFT_VERSION: "6.0\"""",
        ),
        (
            """        CFBundleShortVersionString: "1.0.0"
        CFBundleVersion: "1\"""",
            """        CFBundleShortVersionString: $(MARKETING_VERSION)
        CFBundleVersion: $(CURRENT_PROJECT_VERSION)""",
        ),
    ],
)

patch(
    ".github/workflows/ios-build.yml",
    [
        (
            """      - name: Build (Release, unsigned)
        run: |
          set -o pipefail
          xcodebuild \\
            -project "${APP_NAME}.xcodeproj" \\
            -scheme "${APP_NAME}" \\
            -configuration Release \\
            -sdk iphoneos \\
            -destination 'generic/platform=iOS' \\
            -derivedDataPath build \\
            CODE_SIGNING_ALLOWED=NO \\
            CODE_SIGNING_REQUIRED=NO \\
            CODE_SIGN_IDENTITY="" \\
            CODE_SIGN_ENTITLEMENTS="" \\
            build 2>&1 | tee build.log""",
            """      - name: Build (Release, unsigned)
        run: |
          set -o pipefail
          # BUILD 号 = Actions run number，保证每个产物都能追溯到具体构建
          xcodebuild \\
            -project "${APP_NAME}.xcodeproj" \\
            -scheme "${APP_NAME}" \\
            -configuration Release \\
            -sdk iphoneos \\
            -destination 'generic/platform=iOS' \\
            -derivedDataPath build \\
            CURRENT_PROJECT_VERSION="${GITHUB_RUN_NUMBER}" \\
            CODE_SIGNING_ALLOWED=NO \\
            CODE_SIGNING_REQUIRED=NO \\
            CODE_SIGN_IDENTITY="" \\
            CODE_SIGN_ENTITLEMENTS="" \\
            build 2>&1 | tee build.log

      - name: Report version
        if: success()
        run: |
          plutil -p "build/Build/Products/Release-iphoneos/${APP_NAME}.app/Info.plist" \\
            | grep -E "CFBundleShortVersionString|CFBundleVersion" || true""",
        ),
    ],
)

print("done")
