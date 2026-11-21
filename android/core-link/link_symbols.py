#!/usr/bin/env python3
"""Android single-library link-symbol check (Q19 / #530).

The APK gate historically did not compile the Android APK. A new shared C#
binding could therefore reference a native entry that the Android single
library never links, and the break stayed invisible until someone tried a full
Docker build. This check closes that specific gap without an Android SDK/NDK:

  1. Collect the C# compile inputs of the Android NativeAOT composition from the
     real project files (MSBuild items, project references, globs, conditions).
  2. Extract every DllImport/LibraryImport entry for the DirectPInvoke libraries
     the static single library binds, including EntryPoint renames and const
     library names.
  3. Collect the definitions the Android target actually links from the shared
     CMake source lists (diagnostic provider + stub, or the real game provider),
     including conditional compilation.
  4. Report one 【红】 line per missing symbol with its C# reference site.

With an NDK (and CMake) the same answer is put through a real ld.lld link of
libs2arm_android.so: a generated probe file references the collected C# entries
and the production native source lists are linked with -z defs. Without NDK the
output says explicitly that only the source-level check ran.

The check is deliberately source-level when no NDK is present: it proves the
provider set covers the C# entries, not that an APK or a device works.
"""

import argparse
import fnmatch
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import warnings
import xml.etree.ElementTree as ET
from pathlib import Path

SCHEMA = 1
DEFAULT_CS_PROJECT = "android/cs/aot/S2A.Android.Aot.csproj"
TARGET_LIBS = ("s2a_native", "s2arm_android")
CODEC_LIBS = ("s2a_opus", "s2a_vpx")
GLOBAL_PROPERTIES = {
    "Configuration": "Release",
    "Platform": "AnyCPU",
    "TargetFramework": "net10.0",
    "RuntimeIdentifier": "linux-bionic-arm64",
    "NativeLib": "Static",
    "DefaultItemExcludes": "",
    "EnableDefaultCompileItems": "true",
}
# cs/build.sh passes these on the command line; project properties must not
# overwrite them while evaluating the static single-library configuration.
GLOBAL_LOCKED = {"Configuration", "Platform", "RuntimeIdentifier", "NativeLib"}


class CheckError(Exception):
    pass


def rel(root, path):
    try:
        return Path(path).resolve().relative_to(Path(root).resolve()).as_posix()
    except ValueError:
        return Path(path).resolve().as_posix()


def strip_cs_comments(text):
    """Remove // and /* */ comments, preserving string/char literals."""
    out = []
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == '"' or c == "'":
            quote = c
            start = i
            i += 1
            while i < n:
                if text[i] == "\\":
                    i += 2
                    continue
                if text[i] == quote:
                    i += 1
                    break
                i += 1
            out.append(text[start:i])
            continue
        if c == "@" and i + 1 < n and text[i + 1] == '"':
            start = i
            i += 2
            while i < n:
                if text[i] == '"':
                    if i + 1 < n and text[i + 1] == '"':
                        i += 2
                        continue
                    i += 1
                    break
                i += 1
            out.append(text[start:i])
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "/":
            j = text.find("\n", i)
            if j < 0:
                break
            i = j
            continue
        if c == "/" and i + 1 < n and text[i + 1] == "*":
            j = text.find("*/", i + 2)
            i = n if j < 0 else j + 2
            out.append(" ")
            continue
        out.append(c)
        i += 1
    return "".join(out)


def strip_c_comments(text):
    return strip_cs_comments(text)


def expand_properties(value, props):
    """Expand the MSBuild subset used by projects in this repository."""
    if value is None:
        return ""

    def full_path(match):
        inner = expand_properties(match.group(1), props)
        base = props.get("MSBuildThisFileDirectory", "")
        result = os.path.abspath(os.path.join(base, inner))
        if inner.endswith(("/", "\\")):
            result = result.rstrip("/\\") + "/"
        return result

    # Common property functions. Keep this list small and explicit: unsupported
    # functions stay visible instead of being guessed into a path.
    value = re.sub(r"\$\(\[System\.IO\.Path\]::GetFullPath\('([^']*)'\)\)", full_path, value)

    def is_os(match):
        platform = match.group(1).strip("'\" ")
        return "true" if platform.lower() in ("linux", "android") else "false"

    value = re.sub(
        r"\$\(\[System\.Runtime\.InteropServices\.RuntimeInformation\]::IsOSPlatform"
        r"\(\$\(\[System\.Runtime\.InteropServices\.OSPlatform\]::([A-Za-z]+)\)\)\)",
        is_os,
        value,
    )

    def prop(match):
        name = match.group(1)
        if name.startswith("MSBuildThisFile"):
            return props.get("MSBuildThisFileDirectory", "")
        return props.get(name, "")

    for _ in range(8):
        new = re.sub(r"\$\(([A-Za-z_][A-Za-z0-9_.]*)\)", prop, value)
        if new == value:
            break
        value = new
    return value


def split_top(text, separator):
    """Split on a top-level boolean operator, ignoring quoted spans."""
    parts = []
    start = 0
    quote = None
    depth = 0
    i = 0
    needle = separator.lower()
    while i <= len(text) - len(needle):
        c = text[i]
        if quote:
            if c == quote:
                quote = None
            i += 1
            continue
        if c in ("'", '"'):
            quote = c
            i += 1
            continue
        if c == "(":
            depth += 1
            i += 1
            continue
        if c == ")":
            depth = max(0, depth - 1)
            i += 1
            continue
        if depth == 0 and text[i:i + len(needle)].lower() == needle:
            parts.append(text[start:i])
            start = i + len(needle)
            i = start
            continue
        i += 1
    parts.append(text[start:])
    return parts


def eval_condition(condition, props):
    """Evaluate the MSBuild condition forms used by the compile closure.

    Unknown syntax is treated as true (include the item): a gate must not
    silently drop a new binding because MSBuild learned a new function.
    """
    if condition is None or not condition.strip():
        return True
    text = expand_properties(condition, props).strip()
    while text.startswith("(") and text.endswith(")") and balanced(text[1:-1]):
        text = text[1:-1].strip()
    if not text:
        return True
    ors = split_top(text, " or ")
    if len(ors) > 1:
        return any(eval_condition(part, props) for part in ors)
    ands = split_top(text, " and ")
    if len(ands) > 1:
        return all(eval_condition(part, props) for part in ands)
    if text.startswith("!"):
        return not eval_condition(text[1:].strip(), props)

    exists = re.fullmatch(r"Exists\s*\(\s*(['\"])(.*?)\1\s*\)", text, re.S)
    if exists:
        return os.path.exists(exists.group(2))

    for op in ("==", "!="):
        if op in text:
            left, right = text.split(op, 1)
            left = left.strip().strip("'\"")
            right = right.strip().strip("'\"")
            return (left == right) if op == "==" else (left != right)

    if text.lower() in ("true", "false"):
        return text.lower() == "true"
    # A bare property that is non-empty is true, matching MSBuild's common use.
    return bool(text)


def balanced(text):
    depth = 0
    quote = None
    for c in text:
        if quote:
            if c == quote:
                quote = None
            continue
        if c in ("'", '"'):
            quote = c
        elif c == "(":
            depth += 1
        elif c == ")":
            depth -= 1
            if depth < 0:
                return False
    return depth == 0


class CompileClosure:
    """Evaluate the C# Compile items for the Android NativeAOT composition."""

    def __init__(self, root, verbose=False):
        self.root = Path(root).resolve()
        self.verbose = verbose
        self.errors = []

    def project_items(self, project):
        project = Path(project).resolve()
        if not project.is_file():
            raise CheckError("C# 工程不存在：%s" % project)
        props = dict(GLOBAL_PROPERTIES)
        props.update({
            "MSBuildThisFileDirectory": project.parent.as_posix().rstrip("/") + "/",
            "MSBuildProjectDirectory": project.parent.as_posix(),
            "MSBuildProjectFullPath": project.as_posix(),
        })
        root = ET.parse(str(project)).getroot()
        self._apply_props(root, props, project)
        files = set()
        if props.get("EnableDefaultCompileItems", "true").lower() != "false":
            for candidate in sorted(project.parent.rglob("*.cs")):
                if self._default_excluded(candidate, project.parent, props):
                    continue
                files.add(candidate.resolve())
        self._apply_items(root, props, project, files)
        refs = []
        for ig in root.findall("ItemGroup"):
            if not eval_condition(ig.get("Condition"), props):
                continue
            for item in ig.findall("ProjectReference"):
                if not eval_condition(item.get("Condition"), props):
                    continue
                if item.get("ReferenceOutputAssembly", "").lower() == "false":
                    continue
                if (item.get("OutputItemType", "") or "").lower() == "analyzer":
                    continue
                include = expand_properties(item.get("Include", ""), props)
                for part in include.split(";"):
                    part = part.strip()
                    if not part:
                        continue
                    refs.append((project.parent / part.replace("\\", "/")).resolve())
        return files, refs

    def _apply_props(self, root, props, project):
        # Directory.Build.props chain, root to project. Only properties/items
        # used by this repository are consumed; no NuGet props are needed.
        ancestors = []
        current = project.parent
        while True:
            candidate = current / "Directory.Build.props"
            if candidate.is_file():
                ancestors.append(candidate)
            if current == self.root or current.parent == current:
                break
            current = current.parent
        for props_file in reversed(ancestors):
            self._apply_props_file(props_file, props)
        self._apply_props_file(project, props)

    def _apply_props_file(self, project, props):
        if project.suffix == ".csproj":
            root = ET.parse(str(project)).getroot()
        else:
            root = ET.parse(str(project)).getroot()
        old_dir = props.get("MSBuildThisFileDirectory")
        props["MSBuildThisFileDirectory"] = project.parent.as_posix().rstrip("/") + "/"
        try:
            for group in root.findall("PropertyGroup"):
                if not eval_condition(group.get("Condition"), props):
                    continue
                for prop in group:
                    if not isinstance(prop.tag, str) or prop.tag in GLOBAL_LOCKED:
                        continue
                    props[prop.tag] = expand_properties(prop.text or "", props)
        finally:
            props["MSBuildThisFileDirectory"] = old_dir
        return root

    def _default_excluded(self, path, project_dir, props):
        try:
            relative = path.relative_to(project_dir).as_posix()
        except ValueError:
            return True
        if any(part in ("bin", "obj") for part in Path(relative).parts):
            return True
        patterns = (props.get("DefaultItemExcludes") or "").split(";")
        for pattern in patterns:
            pattern = pattern.strip()
            if not pattern:
                continue
            if fnmatch.fnmatch(relative, pattern) or fnmatch.fnmatch(path.name, pattern):
                return True
        return False

    def _compile_matches(self, pattern, base, props):
        pattern = expand_properties(pattern, props).strip().replace("\\", "/")
        if not pattern:
            return []
        if "%(" in pattern:
            # Item metadata in Include is not used for Compile paths here.
            return []
        if not os.path.isabs(pattern):
            pattern = (base / pattern).as_posix()
        matches = glob.glob(pattern, recursive=True)
        return [Path(m).resolve() for m in matches if Path(m).is_file() and Path(m).suffix == ".cs"]

    def _apply_items(self, root, props, project, files):
        for group in root.findall("ItemGroup"):
            if not eval_condition(group.get("Condition"), props):
                continue
            for item in group:
                if not isinstance(item.tag, str) or item.tag != "Compile":
                    continue
                if not eval_condition(item.get("Condition"), props):
                    continue
                include = item.get("Include")
                remove = item.get("Remove")
                exclude = item.get("Exclude")
                if include:
                    for part in include.split(";"):
                        files.update(self._compile_matches(part, project.parent, props))
                if remove:
                    for part in remove.split(";"):
                        for match in self._compile_matches(part, project.parent, props):
                            files.discard(match)
                if exclude:
                    for part in exclude.split(";"):
                        for match in self._compile_matches(part, project.parent, props):
                            files.discard(match)

    def closure(self, projects):
        pending = [Path(p).resolve() for p in projects]
        seen = set()
        files = set()
        project_files = []
        while pending:
            project = pending.pop()
            canonical = project.resolve()
            if canonical in seen:
                continue
            seen.add(canonical)
            project_files.append(canonical)
            found, refs = self.project_items(canonical)
            files.update(found)
            pending.extend(refs)
        return sorted(files), project_files


def parse_cs_exports(files, root):
    exports = []
    attr_re = re.compile(
        r"\[\s*(?:[A-Za-z_][A-Za-z0-9_]*\.)*UnmanagedCallersOnly\s*(?:\(([^\]]*)\))?\s*\]",
        re.S,
    )
    method_re = re.compile(
        r"(?:extern|static|public|private|internal|protected|unsafe|partial|new|override|\s)+"
        r"[\w<>\[\],\.\?\*]+\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("
    )
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        if "UnmanagedCallersOnly" not in text:   # most files: skip the comment pass
            continue
        text = strip_cs_comments(text)
        for match in attr_re.finditer(text):
            attrs = match.group(1) or ""
            entry = re.search(r"EntryPoint\s*=\s*\"([^\"]+)\"", attrs)
            if entry:
                symbol = entry.group(1)
            else:
                rest = text[match.end():match.end() + 400]
                method = method_re.search(rest)
                if not method:
                    continue
                symbol = method.group(1)
            exports.append({
                "symbol": symbol,
                "path": rel(root, path),
                "line": text.count("\n", 0, match.start()) + 1,
            })
    unique = {}
    for item in exports:
        unique[(item["symbol"], item["path"], item["line"])] = item
    return list(unique.values())


def parse_cs_imports(files, root, verbose=False, libraries=None):
    libraries = set(libraries or (TARGET_LIBS + CODEC_LIBS))
    imports = []
    runtime_lookups = []
    unresolved = []
    attr_re = re.compile(
        r"\[\s*(?:[A-Za-z_][A-Za-z0-9_]*\.)*(DllImport|LibraryImport)\s*\(([^\]]*)\)\s*\]",
        re.S,
    )
    method_re = re.compile(
        r"(?:extern|static|public|private|internal|protected|unsafe|partial|new|override|\s)+"
        r"[\w<>\[\],\.\?\*]+\s+([A-Za-z_][A-Za-z0-9_]*)\s*\("
    )
    for path in files:
        text = path.read_text(encoding="utf-8", errors="replace")
        if "Import" not in text:   # no DllImport / LibraryImport: skip the comment pass
            continue
        text = strip_cs_comments(text)
        consts = dict(re.findall(r"\bconst\s+string\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\"([^\"]*)\"", text))
        for match in attr_re.finditer(text):
            kind, attrs = match.group(1), match.group(2)
            lib_match = re.search(r"\"([^\"]*)\"", attrs)
            if lib_match:
                library = lib_match.group(1)
            else:
                ident = re.match(r"\s*([A-Za-z_][A-Za-z0-9_]*)", attrs)
                if not ident or ident.group(1) not in consts:
                    unresolved.append({
                        "path": rel(root, path),
                        "line": text.count("\n", 0, match.start()) + 1,
                        "reason": "无法解析库名",
                    })
                    continue
                library = consts[ident.group(1)]
            if library not in libraries:
                continue
            entry = re.search(r"EntryPoint\s*=\s*\"([^\"]+)\"", attrs)
            if entry:
                symbol = entry.group(1)
            else:
                rest = text[match.end():match.end() + 600]
                method = method_re.search(rest)
                if not method:
                    unresolved.append({
                        "path": rel(root, path),
                        "line": text.count("\n", 0, match.start()) + 1,
                        "reason": "无法解析方法名",
                    })
                    continue
                symbol = method.group(1)
            imports.append({
                "library": library,
                "symbol": symbol,
                "path": rel(root, path),
                "line": text.count("\n", 0, match.start()) + 1,
                "kind": kind,
                "method": None if entry else symbol,
            })
        for match in re.finditer(r"NativeLibrary\.(?:TryGetExport|GetExport)\s*\([^;]*?\"(s2a_[A-Za-z0-9_]+)\"", text, re.S):
            runtime_lookups.append({
                "symbol": match.group(1),
                "path": rel(root, path),
                "line": text.count("\n", 0, match.start()) + 1,
            })
    # Stable de-duplication while keeping all reference sites for missing lines.
    unique = {}
    for item in imports:
        key = (item["library"], item["symbol"], item["path"], item["line"])
        unique[key] = item
    return list(unique.values()), runtime_lookups, unresolved


class Defines:
    def __init__(self, mode):
        self.values = {
            "__ANDROID__": "1",
            "ANDROID": "1",
            "__aarch64__": "1",
            "__linux__": "1",
            "__ELF__": "1",
            "_GNU_SOURCE": "1",
            "MREMAP_FIXED": "1",
            "MREMAP_MAYMOVE": "1",
            "TARGET_OS_IPHONE": "0",
            "TARGET_OS_OSX": "0",
            "S2A_VAMM_BALANCED": "0",
            "VK_USE_PLATFORM_ANDROID_KHR": "1",
            "S2A_CS_STATIC": "1",
        }
        if mode == "game":
            self.values["S2A_ANDROID_GAME_RUNTIME"] = "1"

    def get(self, name, default="0"):
        return self.values.get(name, default)


def preprocess_active_lines(text, defines, verbose=False):
    """Select lines active under the Android build's object macros.

    Handles #if/#ifdef/#ifndef/#elif/#else/#endif, defined(), !, &&, ||,
    comparisons and __has_include. Function-like macros are left alone; this
    only decides which source lines participate in the definition scan.
    """
    # Comments go first, as in the C preprocessor: a trailing // or /* */ on a directive is not part
    # of its condition or macro value (string literals keep their "//").
    text = strip_c_comments(text.replace("\r\n", "\n"))
    lines = text.split("\n")
    # Join directive continuations so a macro definition is one logical line.
    logical = []
    i = 0
    while i < len(lines):
        line = lines[i]
        while line.rstrip().endswith("\\") and i + 1 < len(lines):
            i += 1
            line = line.rstrip()[:-1] + lines[i]
        logical.append(line)
        i += 1
    stack = []  # (parent_active, branch_taken, active)
    active = True
    out = []
    for line in logical:
        stripped = line.lstrip()
        if not stripped.startswith("#"):
            if active:
                out.append(line)
            continue
        directive = stripped[1:].strip()
        if not directive:
            continue
        name, _, rest = directive.partition(" ")
        name = name.strip()
        rest = rest.strip()
        if name in ("if", "ifdef", "ifndef"):
            parent = active
            if name == "ifdef":
                value = defines.get(rest.split()[0], "0") != "0" if rest else False
            elif name == "ifndef":
                value = defines.get(rest.split()[0], "0") == "0" if rest else True
            else:
                value = eval_cpp_condition(rest, defines, verbose)
            stack.append([parent, bool(value), parent and bool(value)])
            active = parent and bool(value)
        elif name == "elif":
            if not stack:
                continue
            parent, taken, _ = stack[-1]
            value = (not taken) and eval_cpp_condition(rest, defines, verbose)
            stack[-1][1] = taken or value
            stack[-1][2] = parent and (taken or value)
            active = stack[-1][2]
        elif name == "else":
            if not stack:
                continue
            parent, taken, _ = stack[-1]
            stack[-1][2] = parent and not taken
            stack[-1][1] = True
            active = stack[-1][2]
        elif name == "endif":
            if stack:
                active = stack.pop()[0]
        elif name == "define" and active:
            parts = rest.split(None, 1)
            if parts and "(" not in parts[0]:
                defines.values[parts[0]] = parts[1].strip() if len(parts) > 1 else "1"
        elif name == "undef" and active:
            defines.values.pop(rest.split()[0] if rest else "", None)
    return "\n".join(out)


def eval_cpp_condition(expr, defines, verbose=False):
    expr = expr.strip()
    expr = re.sub(r"__has_include\s*\([^)]*\)", "1", expr)
    expr = re.sub(
        r"defined\s*\(\s*([A-Za-z_][A-Za-z0-9_]*)\s*\)",
        lambda m: "1" if m.group(1) in defines.values else "0",
        expr,
    )
    expr = re.sub(
        r"defined\s+([A-Za-z_][A-Za-z0-9_]*)",
        lambda m: "1" if m.group(1) in defines.values else "0",
        expr,
    )
    expr = re.sub(r"\b([A-Za-z_][A-Za-z0-9_]*)\b", lambda m: "1" if m.group(1) == "true" else ("0" if m.group(1) == "false" else defines.get(m.group(1), "0")), expr)
    expr = expr.replace("&&", " and ").replace("||", " or ")
    expr = re.sub(r"!(?!=)", " not ", expr)
    # Drop C suffixes and any residual identifiers.
    expr = re.sub(r"\b(0x[0-9A-Fa-f]+|\d+)[uUlL]+\b", r"\1", expr)
    if re.search(r"[^0-9a-fA-FxX\s()<>!=+\-*/%andornot.]", expr):
        # Unknown token: include the block rather than silently dropping a
        # definition that the real preprocessor might select.
        return True
    try:
        with warnings.catch_warnings():   # function-like macros become "0(0)": Python warns before raising; the except below includes the block
            warnings.simplefilter("ignore", SyntaxWarning)
            return bool(eval(expr, {"__builtins__": {}}, {}))
    except Exception:
        if verbose:
            print("警告：无法求值预处理条件，按包含处理：%s" % expr)
        return True


def c_definitions(path, defines, verbose=False):
    raw = path.read_text(encoding="utf-8", errors="replace")
    text = preprocess_active_lines(raw, defines, verbose)
    definitions = []
    depth = 0
    extern_c_depth = None
    i = 0
    n = len(text)
    while i < n:
        c = text[i]
        if c == "{":
            # Track extern "C" blocks in C++ files.
            prefix = text[max(0, i - 40):i]
            if re.search(r'extern\s*"C"\s*$', prefix):
                extern_c_depth = depth + 1
            depth += 1
            i += 1
            continue
        if c == "}":
            depth = max(0, depth - 1)
            if extern_c_depth is not None and depth < extern_c_depth:
                extern_c_depth = None
            i += 1
            continue
        match = re.match(r"(s2a_[A-Za-z0-9_]+)\s*\(", text[i:])
        if match and (i == 0 or not (text[i - 1].isalnum() or text[i - 1] == "_")):
            name = match.group(1)
            allowed = depth == 0 or (extern_c_depth is not None and depth == extern_c_depth)
            j = i + match.end()
            paren = 1
            while j < n and paren:
                if text[j] == "(":
                    paren += 1
                elif text[j] == ")":
                    paren -= 1
                j += 1
            # Optional attributes and whitespace before the body.
            k = j
            while k < n:
                if text[k] in " \t\r\n":
                    k += 1
                    continue
                if text.startswith("__attribute__", k):
                    attr_end = text.find(")", k)
                    # Consume a balanced attribute invocation.
                    p = text.find("(", k)
                    if p < 0:
                        break
                    pd = 0
                    while p < n:
                        if text[p] == "(":
                            pd += 1
                        elif text[p] == ")":
                            pd -= 1
                            if pd == 0:
                                p += 1
                                break
                        p += 1
                    k = p
                    continue
                break
            if allowed and k < n and text[k] == "{":
                prefix = text[max(0, i - 240):i]
                cut = max(prefix.rfind(";"), prefix.rfind("}"), prefix.rfind("{"))
                prefix = prefix[cut + 1:]
                is_static = re.search(r"\bstatic\b", prefix) is not None
                is_weak = "weak" in prefix or "weak" in text[j:k]
                definitions.append({
                    "symbol": name,
                    "path": path,
                    "line": text.count("\n", 0, i) + 1,
                    "static": is_static,
                    "weak": is_weak,
                })
            i = i + match.end()
            continue
        i += 1
    return definitions


def asm_definitions(path):
    text = path.read_text(encoding="utf-8", errors="replace")
    names = set()
    for match in re.finditer(r"(?m)^\s*\.(?:globl|global)\s+([A-Za-z_][A-Za-z0-9_]*)", text):
        if match.group(1).startswith("s2a_"):
            names.add(match.group(1))
    return [{"symbol": name, "path": path, "line": 1, "static": False, "weak": False} for name in sorted(names)]


def cmake_native_sources(root, mode, cmake="cmake", verbose=False):
    work = Path(tempfile.mkdtemp(prefix="s2a-link-sources-"))
    try:
        script = work / "sources.cmake"
        listing = work / "sources.txt"
        script.write_text(
            'include("%s")\n'
            'set(S2A_ANDROID_EXPERIMENTAL_TOUCH OFF)\n'
            's2a_android_link_sources(SOURCES "%s" "static")\n'
            'file(WRITE "%s" "${SOURCES}")\n'
            % ((Path(root) / "android/core-link/LinkSources.cmake").as_posix(), mode, listing.as_posix()),
            encoding="utf-8",
        )
        result = subprocess.run([cmake, "-P", str(script)], capture_output=True, text=True)
        if result.returncode:
            raise CheckError("CMake 源清单求值失败（%s）：%s" % (mode, (result.stderr or result.stdout).strip()))
        entries = [item for item in listing.read_text(encoding="utf-8").split(";") if item.strip()]
    finally:
        shutil.rmtree(work, ignore_errors=True)
    base = Path(root) / "android"
    files = []
    for entry in entries:
        path = Path(entry)
        if not path.is_absolute():
            path = base / path
        files.append(path.resolve())
    if verbose:
        print("原生源清单（%s，%d 个）：" % (mode, len(files)))
        for path in files:
            print("  " + rel(root, path))
    return files


def expand_local_includes(files, root):
    """Add repository .inc/.c files included by the selected sources.

    boot.c on Android includes boot_android.inc, which owns s2a_boot_mark.
    Headers only declare symbols; including them would not add definitions and
    can only confuse the scanner, so they are skipped.
    """
    root = Path(root).resolve()
    seen = set(Path(path).resolve() for path in files)
    pending = list(seen)
    while pending:
        path = pending.pop()
        if path.suffix not in (".c", ".cc", ".cpp", ".cxx", ".inc"):
            continue
        try:
            text = path.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for match in re.finditer(r'^\s*#\s*include\s+"([^"]+)"', text, re.M):
            candidate = (path.parent / match.group(1)).resolve()
            try:
                candidate.relative_to(root)
            except ValueError:
                continue
            if candidate.is_file() and candidate.suffix in (".inc", ".c") and candidate not in seen:
                seen.add(candidate)
                pending.append(candidate)
    return sorted(seen)


def collect_definitions(files, mode, root, verbose=False):
    defines = Defines(mode)
    definitions = []
    for path in expand_local_includes(files, root):
        if not path.is_file():
            continue
        if path.suffix in (".c", ".cc", ".cpp", ".cxx", ".inc"):
            definitions.extend(c_definitions(path, defines, verbose))
        elif path.suffix in (".S", ".s", ".asm"):
            definitions.extend(asm_definitions(path))
    return definitions


def check_once(root, mode, cs_projects, native_files=None, verbose=False, cmake="cmake", cs_cache=None):
    root = Path(root).resolve()
    if cs_cache is None:
        cs_cache = {}
    if "files" not in cs_cache:
        closure = CompileClosure(root, verbose)
        cs_files, projects = closure.closure(cs_projects)
        direct = direct_pinvoke_libraries(cs_projects)
        imports, runtime_lookups, unresolved = parse_cs_imports(
            cs_files, root, verbose, direct or (TARGET_LIBS + CODEC_LIBS))
        cs_exports = parse_cs_exports(cs_files, root)
        cs_cache.update({
            "files": cs_files,
            "projects": projects,
            "direct_pinvoke": direct,
            "imports": imports,
            "runtime_lookups": runtime_lookups,
            "unresolved": unresolved,
            "cs_exports": cs_exports,
        })
    cs_files = cs_cache["files"]
    projects = cs_cache["projects"]
    direct = cs_cache.get("direct_pinvoke", set())
    imports = cs_cache["imports"]
    runtime_lookups = cs_cache["runtime_lookups"]
    unresolved = list(cs_cache["unresolved"])
    cs_exports = cs_cache["cs_exports"]
    if native_files is None:
        native_files = cmake_native_sources(root, mode, cmake, verbose)
    # The codec shims are compiled into the static single library as their own
    # archives (codecs/build.sh); their s2a_* wrappers are checked here, while
    # the bundled third-party opus/vpx entry points are link-only (below).
    definition_files = list(native_files)
    for shim in ("services/opus/s2a_opus.c", "services/vpx/s2a_vp8.c",
                 "services/vpx/s2a_vp9.c", "android/codecs/s2a_avc.c"):
        candidate = root / shim
        if candidate.is_file() and candidate not in definition_files:
            definition_files.append(candidate)
    definitions = collect_definitions(definition_files, mode, root, verbose)

    defs_by_symbol = {}
    for definition in definitions:
        defs_by_symbol.setdefault(definition["symbol"], []).append(definition)

    missing = []
    third_party = []
    required = []
    known_libraries = set(TARGET_LIBS + CODEC_LIBS)
    for item in imports:
        library, symbol = item["library"], item["symbol"]
        if library not in known_libraries:
            unresolved.append({
                "path": item["path"],
                "line": item["line"],
                "reason": "DirectPInvoke 库 %s 没有源码定义清单，无法核对" % library,
            })
            continue
        if library in CODEC_LIBS and not symbol.startswith("s2a_"):
            third_party.append(item)
            continue
        required.append(item)
        candidates = [d for d in defs_by_symbol.get(symbol, []) if not d["static"]]
        if not candidates:
            missing.append(item)

    duplicates = []
    for symbol in sorted({item["symbol"] for item in required}):
        strong = [d for d in defs_by_symbol.get(symbol, []) if not d["static"] and not d["weak"]]
        if len(strong) > 1:
            duplicates.append({
                "symbol": symbol,
                "definitions": [{"path": rel(root, d["path"]), "line": d["line"]} for d in strong],
            })

    return {
        "mode": mode,
        "cs_projects": [rel(root, p) for p in projects],
        "direct_pinvoke": sorted(direct),
        "cs_files": len(cs_files),
        "native_files": sorted(rel(root, p) for p in native_files),
        "imports": imports,
        "required": required,
        "runtime_lookups": runtime_lookups,
        "cs_exports": cs_exports,
        "unresolved": unresolved,
        "definitions": len(definitions),
        "native_symbols": sorted({d["symbol"] for d in definitions if not d["static"]}),
        "missing": missing,
        "duplicates": duplicates,
        "third_party_unchecked": third_party,
    }


def direct_pinvoke_libraries(projects):
    libraries = set()
    for project in projects:
        try:
            root = ET.parse(str(project)).getroot()
        except (OSError, ET.ParseError):
            continue
        for item in root.iter("DirectPInvoke"):
            if (item.text or "").strip():
                libraries.add(item.text.strip())
    return libraries


HOMEBREW_NDK_PATHS = (Path("/opt/homebrew/share/android-ndk"), Path("/usr/local/share/android-ndk"))
HOMEBREW_CMAKE_PATHS = (Path("/opt/homebrew/bin/cmake"), Path("/usr/local/bin/cmake"))


def ndk_candidates():
    candidates = []
    for name in ("ANDROID_NDK_HOME", "ANDROID_NDK_ROOT"):
        value = os.environ.get(name)
        if value:
            candidates.append(Path(value))
    for name in ("ANDROID_HOME", "ANDROID_SDK_ROOT"):
        value = os.environ.get(name)
        if value:
            candidates.append(Path(value) / "ndk/29.0.14206865")
    home = Path.home()
    candidates.extend([
        home / "Library/Android/sdk/ndk/29.0.14206865",
        home / "Android/Sdk/ndk/29.0.14206865",
    ])
    candidates.extend(HOMEBREW_NDK_PATHS)
    return candidates


def find_ndk():
    for candidate in ndk_candidates():
        if (candidate / "source.properties").is_file() and any(
                line.strip() == "Pkg.Revision = 29.0.14206865"
                for line in (candidate / "source.properties").read_text(errors="replace").splitlines()):
            return candidate
    return None


def find_q19_cmake(explicit=None):
    """Resolve CMake independently of the selected NDK, with version validation."""
    candidates = []
    if explicit is not None:
        candidates.append(shutil.which(explicit) or explicit)
    else:
        on_path = shutil.which("cmake")
        if on_path:
            candidates.append(on_path)
        sdk_roots = [Path(os.environ[name]) for name in ("ANDROID_HOME", "ANDROID_SDK_ROOT")
                     if os.environ.get(name)]
        home = Path.home()
        sdk_roots.extend((home / "Library/Android/sdk", home / "Android/Sdk"))
        for sdk in sdk_roots:
            root = sdk / "cmake"
            candidates.append(str(root / "3.31.6/bin/cmake"))
            candidates.extend(str(path) for path in sorted(root.glob("*/bin/cmake"), reverse=True))
        candidates.extend(str(path) for path in HOMEBREW_CMAKE_PATHS)
    unique = list(dict.fromkeys(str(path) for path in candidates))
    for path in unique:
        try:
            result = subprocess.run([path, "--version"], capture_output=True, text=True, timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            continue
        match = re.match(r"^cmake version (\d+)\.(\d+)\.(\d+)(?:-g[0-9a-f]+)?(?:\s|$)", result.stdout)
        if result.returncode == 0 and match and tuple(map(int, match.groups())) >= (3, 31, 6):
            return path
    raise CheckError("Q19 需要 CMake >=3.31.6；已查 " + repr(unique) +
                     "；安装：brew install cmake，或 sdkmanager 'cmake;3.31.6'；可设 CMAKE")


def write_probe(path, symbols, exports=(), native_symbols=()):
    lines = ["/* generated by android/core-link/link_symbols.py */"]
    unique = sorted(set(symbols))
    for index, symbol in enumerate(unique):
        lines.append("extern void %s(void);" % symbol)
        lines.append("__attribute__((used)) void *const s2a_link_probe_%d = (void *)&%s;" % (index, symbol))
    # Native code calls managed [UnmanagedCallersOnly] exports. The real
    # archive supplies them; a native-only probe needs harmless definitions.
    defined = set(native_symbols)
    for symbol in sorted(set(exports)):
        if symbol in defined:
            continue
        lines.append("__attribute__((used)) void %s(void) {}" % symbol)
        defined.add(symbol)
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")
    return len(unique)


def avc_probe_archive(root, ndk, cmake=None):
    """Use a real codec archive; build it only from the pinned offline source."""
    explicit = os.environ.get("S2A_Q19_AVC_ARCHIVE")
    if explicit is not None:
        if not explicit or not Path(explicit).is_file():
            raise CheckError("S2A_Q19_AVC_ARCHIVE 未指向真实 libavc 归档")
        return str(Path(explicit).resolve())
    env = dict(os.environ)
    # The codec builder uses sha256sum; Homebrew coreutils installs it here
    # on macOS even when the interactive PATH does not include gnubin.
    gnubin = Path('/opt/homebrew/opt/coreutils/libexec/gnubin')
    if sys.platform == 'darwin' and gnubin.is_dir():
        env['PATH'] = str(gnubin) + os.pathsep + env.get('PATH', '')
    # A Homebrew NDK is not necessarily inside $ANDROID_HOME/ndk. Pass the
    # exact checked toolchain to the offline AVC build instead of rebuilding
    # a potentially unrelated path from the SDK variable.
    env["S2A_Q19_NDK"] = str(ndk)
    env["CMAKE"] = cmake if cmake is not None else find_q19_cmake(os.environ.get("CMAKE"))
    script = Path(root) / "android/codecs/build.sh"
    result = subprocess.run(["bash", str(script), "--avc-only"], env=env,
                            capture_output=True, text=True)
    if result.returncode:
        raise CheckError("libavc 离线构建失败；准备固定源码或设 S2A_Q19_AVC_ARCHIVE：%s" %
                         (result.stderr or result.stdout).strip()[-1200:])
    paths = [line.strip() for line in result.stdout.splitlines() if line.strip()]
    if len(paths) != 1 or not Path(paths[0]).is_file():
        raise CheckError("libavc 离线构建未返回唯一真实归档")
    return str(Path(paths[0]).resolve())


def link_probe(root, mode, symbols, exports, native_symbols, ndk, verbose=False, cmake="cmake"):
    """Link the production native sources plus generated references with ld.lld."""
    toolchain = ndk / "build/cmake/android.toolchain.cmake"
    if not toolchain.is_file():
        raise CheckError("NDK 缺 CMake 工具链：%s" % toolchain)
    work = Path(tempfile.mkdtemp(prefix="s2a-link-probe-"))
    try:
        probe_c = work / "probe.c"
        count = write_probe(probe_c, symbols, exports, native_symbols)
        build = work / "build"
        args = [
            cmake, "-S", str(Path(root) / "android"), "-B", str(build),
            "-G", "Unix Makefiles",
            "-DCMAKE_TOOLCHAIN_FILE=" + str(toolchain),
            "-DANDROID_ABI=arm64-v8a", "-DANDROID_PLATFORM=android-34",
            "-DCMAKE_BUILD_TYPE=Release",
            "-DS2A_ANDROID_NATIVE_MODE=" + mode,
            "-DS2A_ANDROID_LINK_PROBE=" + str(probe_c),
        ]
        if any(symbol.startswith("s2a_avc_") for symbol in symbols):
            args.append("-DS2A_ANDROID_LINK_AVC_ARCHIVE=" + avc_probe_archive(root, ndk, cmake))
        result = subprocess.run(args, capture_output=True, text=True)
        if result.returncode:
            raise CheckError("libs2arm_android.so 配置失败：%s" % (result.stderr or result.stdout)[-2000:])
        result = subprocess.run([cmake, "--build", str(build), "--target", "s2arm_android", "--parallel", "2"],
                                capture_output=True, text=True)
        library = build / "libs2arm_android.so"
        if result.returncode:
            raise CheckError("libs2arm_android.so 链接失败：%s" % (result.stderr or result.stdout)[-3000:])
        if not library.is_file():
            raise CheckError("libs2arm_android.so 未产出")
        return {
            "attempted": True,
            "result": "pass",
            "ndk": str(ndk),
            "symbols": count,
            "library": str(library),
            "size": library.stat().st_size,
            "temporary": True,
        }
    finally:
        shutil.rmtree(work, ignore_errors=True)


def print_findings(results, root, verbose=False):
    bad = False
    for result in results:
        label = "诊断" if result["mode"] == "diagnostic" else "游戏"
        if result["missing"]:
            bad = True
            for item in result["missing"]:
                print("【红】Android 单库链接符号缺失（%s）：%s:%s ← %s:%d" % (
                    label, item["library"], item["symbol"], item["path"], item["line"]))
        if result["duplicates"]:
            bad = True
            for item in result["duplicates"]:
                sites = ", ".join("%s:%d" % (d["path"], d["line"]) for d in item["definitions"])
                print("【红】Android 单库链接符号重复定义（%s）：%s ← %s" % (label, item["symbol"], sites))
        if result["unresolved"]:
            bad = True
            for item in result["unresolved"]:
                print("【红】Android 单库 C# 导入无法解析：%s:%d（%s）" % (item["path"], item["line"], item["reason"]))
        if verbose:
            print("%s：C# 输入 %d 个文件、入口 %d、原生定义 %d、第三方归档入口 %d、运行时查找 %d" % (
                label, result["cs_files"], len(result["required"]), result["definitions"],
                len(result["third_party_unchecked"]), len(result["runtime_lookups"])))
    return bad


def main(argv=None):
    parser = argparse.ArgumentParser(description="Android 单库链接符号核对（Q19/#530）")
    parser.add_argument("--root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--mode", choices=("diagnostic", "game", "all"), default="all")
    parser.add_argument("--cs-project", action="append", default=None,
                        help="C# 工程（可重复；默认 Android NativeAOT 工程）")
    parser.add_argument("--native-sources", metavar="FILE",
                        help="原生源清单（一行一个；默认由 LinkSources.cmake 求值）")
    parser.add_argument("--report", help="写 JSON 报告")
    parser.add_argument("--verbose", action="store_true")
    parser.add_argument("--no-link", action="store_true", help="不做 NDK 真实链接探针")
    parser.add_argument("--cmake", default=os.environ.get("CMAKE"))
    args = parser.parse_args(argv)
    ndk = find_ndk()
    cmake = find_q19_cmake(args.cmake) if ndk and not args.no_link else (args.cmake or "cmake")
    root = Path(args.root).resolve()
    projects = [Path(p) if Path(p).is_absolute() else root / p for p in (args.cs_project or [DEFAULT_CS_PROJECT])]
    native_override = None
    if args.native_sources:
        native_override = []
        for line in Path(args.native_sources).read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line:
                continue
            path = Path(line)
            native_override.append(path if path.is_absolute() else root / path)
    modes = ("diagnostic", "game") if args.mode == "all" else (args.mode,)
    results = []
    cs_cache = {}
    for mode in modes:
        result = check_once(root, mode, projects, native_override, args.verbose, cmake, cs_cache)
        results.append(result)
    bad = print_findings(results, root, args.verbose)
    link = {"attempted": False, "reason": "未找到 NDK 29.0.14206865（仅符号核对）"}
    if ndk and not args.no_link and not bad:
        # libavc supplies s2arm_android entries through a real pinned archive;
        # third-party Opus/VPX entry points remain covered by the formal build.
        targets = [r for r in results if r["mode"] in ("diagnostic", "game")]
        link = {}
        for result in targets:
            # Core and libavc symbols share s2arm_android and must all link.
            symbols = [item["symbol"] for item in result["required"] if item["library"] in TARGET_LIBS]
            exports = [item["symbol"] for item in result["cs_exports"]]
            try:
                link[result["mode"]] = link_probe(
                    root, result["mode"], symbols, exports, result["native_symbols"],
                    ndk, args.verbose, cmake)
            except CheckError as error:
                link[result["mode"]] = {"attempted": True, "result": "fail", "ndk": str(ndk), "error": str(error)}
                print("【红】Android 单库真实链接失败（%s）：%s" % (result["mode"], " ".join(str(error).splitlines())))
                bad = True
                # A failed prerequisite/link already makes the gate red; do
                # not repeat the same missing-source error for the next mode.
                break
        if not link:
            link = {"attempted": False, "reason": "无结果"}
    elif not ndk:
        print("仅符号核对：未找到 Android NDK 29.0.14206865，未链接 libs2arm_android.so")
    elif bad:
        link = {"attempted": False, "reason": "符号核对已失败，未做真实链接"}

    # A mixed pass/fail is not a complete probe. In particular do not print
    # diagnostic/game as passed merely because one of the two linked.
    link_passed = bool(modes) and all(
        isinstance(link.get(mode), dict) and link[mode].get("result") == "pass" for mode in modes
    )
    report = {
        "schema": SCHEMA,
        "root": str(root),
        "scope": "link-probe" if link_passed else "source-symbol-check",
        "results": results,
        "link": link,
    }
    if args.report:
        Path(args.report).write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    for result in results:
        label = "诊断" if result["mode"] == "diagnostic" else "游戏"
        print("Android 单库符号核对（%s）：C# 入口 %d，缺失 %d，重复 %d" % (
            label, len(result["required"]), len(result["missing"]), len(result["duplicates"])))
    if link_passed:
        modes = "/".join(sorted(link.keys()))
        print("真实链接：libs2arm_android.so（ld.lld -z defs，%s）通过；仅探针引用 C# 入口，未冒充 APK" % modes)
    if bad:
        return 1
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except CheckError as error:
        print("【红】Android 单库符号核对失败：%s" % error, file=sys.stderr)
        sys.exit(1)
