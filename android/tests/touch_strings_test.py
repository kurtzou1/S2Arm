#!/usr/bin/env python3
# SPDX-License-Identifier: Apache-2.0
# Copyright 2026 S2Arm contributors
"""Touch menu strings: English default and Simplified Chinese must stay in step."""
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

KEYS = [
    "touch_menu_import",
    "touch_menu_export",
    "touch_layout_imported",
    "touch_layout_exported",
    "touch_layout_import_failed",
    "touch_layout_export_failed",
    "touch_layout_document_unavailable",
    "touch_layout_err_size",
    "touch_layout_err_invalid",
    "touch_layout_err_read",
    "touch_layout_err_write",

    "touch_menu_title",
    "touch_menu_edit_positions",
    "touch_menu_restore_default",
    "touch_menu_show_pad",
    "touch_menu_hide_pad",
    "touch_passthrough_on",
    "touch_passthrough_off",
    "touch_edit_save",
    "touch_edit_default",
    "touch_edit_cancel",
    "touch_layout_load_failed",
    "touch_layout_save_failed",
]
OLD_LITERALS = [
    '"Touch controls"',
    '"Edit button positions"',
    '"Restore default layout"',
    '"Touch passthrough: on (tap to turn off)"',
    '"Touch passthrough: off (tap to turn on)"',
    '"Saved touch layout could not be read; using the default"',
    '"Layout not saved: "',
    '{"Save", "Default", "Cancel"}',
]


def fail(message):
    print("FAIL: " + message)
    raise SystemExit(1)


def read_strings(path):
    if not path.is_file():
        fail("missing " + str(path))
    root = ET.parse(path).getroot()
    return {node.get("name"): node.text or "" for node in root.findall("string")}


def placeholders(text):
    return sorted(re.findall(r"%\d+\$[sd]", text))


def main():
    app = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / "app" / "src" / "main"
    english = read_strings(app / "res" / "values" / "strings.xml")
    chinese = read_strings(app / "res" / "values-zh" / "strings.xml")
    main_java = (app / "java" / "org" / "s2arm" / "android" / "MainActivity.java").read_text(encoding="utf-8")

    for key in KEYS:
        if key not in english:
            fail("missing values/" + key)
        if key not in chinese:
            fail("missing values-zh/" + key)
        if placeholders(english[key]) != placeholders(chinese[key]):
            fail(key + ": placeholder mismatch")
        if not any(ord(ch) > 127 for ch in chinese[key]):
            fail(key + ": values-zh has no Chinese characters")

    for literal in OLD_LITERALS:
        if literal in main_java:
            fail("hardcoded menu text still in MainActivity: " + literal)

    used = set(re.findall(r"R\.string\.(touch_[A-Za-z0-9_]+)", main_java))
    missing = set(KEYS) - used
    if missing:
        fail("MainActivity does not reference " + ", ".join(sorted(missing)))

    print("touch strings: %d keys bilingual, no hardcoded menu text" % len(KEYS))


if __name__ == "__main__":
    main()
