#!/usr/bin/env python3
"""Validate a generated LoxBerry plugin repository."""

from __future__ import annotations

import configparser
import re
import sys
from pathlib import Path


NAME_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
REQUIRED_FILES = [
    "plugin.cfg",
    "release.cfg",
    "README.md",
    "LICENSE",
    "config/default.json",
    "daemon/daemon",
    "docs/LOXONE_CONFIG.md",
]


def fail(message: str) -> str:
    return f"FAIL: {message}"


def warn(message: str) -> str:
    return f"WARN: {message}"


def validate_plugin_cfg(root: Path) -> list[str]:
    issues: list[str] = []
    cfg_path = root / "plugin.cfg"
    parser = configparser.ConfigParser()
    parser.optionxform = str
    parser.read(cfg_path, encoding="utf-8-sig")

    for section in ["AUTHOR", "PLUGIN", "AUTOUPDATE", "SYSTEM"]:
        if not parser.has_section(section):
            issues.append(fail(f"plugin.cfg missing [{section}] section"))

    if not parser.has_section("PLUGIN"):
        return issues

    plugin = parser["PLUGIN"]
    for key in ["VERSION", "NAME", "FOLDER", "TITLE"]:
        if not plugin.get(key, "").strip():
            issues.append(fail(f"plugin.cfg missing PLUGIN.{key}"))

    if parser.has_section("SYSTEM") and not parser["SYSTEM"].get("INTERFACE", "").strip():
        issues.append(fail("plugin.cfg missing SYSTEM.INTERFACE"))

    name = plugin.get("NAME", "").strip()
    folder = plugin.get("FOLDER", "").strip()
    if name and not NAME_RE.match(name):
        issues.append(fail("PLUGIN.NAME must be lowercase letters, digits, and hyphens"))
    if folder and not NAME_RE.match(folder):
        issues.append(fail("PLUGIN.FOLDER must be lowercase letters, digits, and hyphens"))
    if name and folder and name != folder:
        issues.append(warn("PLUGIN.NAME and PLUGIN.FOLDER usually should match"))

    return issues


def validate_text(root: Path, plugin_name: str) -> list[str]:
    issues: list[str] = []
    daemon_files = list((root / "bin").glob("*.py")) if (root / "bin").exists() else []
    if not daemon_files:
        issues.append(warn("no Python daemon found in bin/"))

    for daemon in daemon_files:
        text = daemon.read_text(encoding="utf-8", errors="replace")
        if "SIGTERM" not in text:
            issues.append(fail(f"{daemon.relative_to(root)} does not handle SIGTERM"))
        if "/opt/loxberry" in text and "fallback" not in text.lower():
            issues.append(warn(f"{daemon.relative_to(root)} contains /opt/loxberry; prefer env vars"))
        if "LBPCONFIGDIR" not in text:
            issues.append(warn(f"{daemon.relative_to(root)} does not reference LBPCONFIGDIR"))
        if "LBPLOGDIR" not in text:
            issues.append(warn(f"{daemon.relative_to(root)} does not reference LBPLOGDIR"))

    docs = root / "docs" / "LOXONE_CONFIG.md"
    if docs.exists():
        doc_text = docs.read_text(encoding="utf-8", errors="replace")
        if plugin_name and f"{plugin_name}/" not in doc_text:
            issues.append(warn("LOXONE_CONFIG.md does not mention plugin MQTT topic prefix"))

    for cgi in (root / "webfrontend").glob("**/*.cgi") if (root / "webfrontend").exists() else []:
        text = cgi.read_text(encoding="utf-8", errors="replace")
        rel = cgi.relative_to(root)
        if "lbputil::" in text:
            issues.append(fail(f"{rel} uses undefined lbputil::* helpers; use LoxBerry::Web::*"))
        if "LoxBerry::Web" in text and "LoxBerry::Web::lbheader" not in text:
            issues.append(warn(f"{rel} references LoxBerry::Web but does not call LoxBerry::Web::lbheader"))
        if "LoxBerry::Web::lbheader" in text and "LoxBerry::Web::lbfooter" not in text:
            issues.append(fail(f"{rel} calls lbheader without lbfooter"))
        if "print $cgi->header" not in text and "LoxBerry::Web::lbheader" not in text:
            issues.append(fail(f"{rel} does not emit an HTTP header"))
        # The installed daemon hook lives at /opt/loxberry/system/daemons/plugins/...
        # not at $lbpbindir/../daemon/daemon (no such file post-install).
        if re.search(r"\$lbpbindir\s*/\s*\.\./\s*daemon", text):
            issues.append(fail(
                f"{rel} restarts the daemon via $lbpbindir/../daemon/daemon — "
                "wrong post-install path; use /opt/loxberry/system/daemons/plugins/<plugin>"
            ))
        # system($daemon, "restart") without output redirection leaks stdout
        # into the HTTP response stream and Apache returns 500.
        if re.search(r"system\s*\(\s*[\"']?\$daemon[\"']?\s*,", text) or re.search(
            r"system\s*\(\s*[\"']\$daemon\s+restart[\"']\s*\)", text
        ):
            issues.append(fail(
                f"{rel} runs `system($daemon, …)` or `system(\"$daemon restart\")` without "
                "redirecting stdout/stderr; subprocess output corrupts the HTTP response. "
                "Redirect via `system(\"$daemon restart >>'$lbplogdir/...log' 2>&1\")`."
            ))

    # HTML::Template templates: stock parser does NOT support EXPR= syntax.
    for tmpl in (root / "templates").glob("**/*.html") if (root / "templates").exists() else []:
        text = tmpl.read_text(encoding="utf-8", errors="replace")
        rel = tmpl.relative_to(root)
        if re.search(r"<TMPL_IF\s+EXPR\s*=", text, re.IGNORECASE):
            issues.append(fail(
                f"{rel} uses <TMPL_IF EXPR=\"...\"> — that's HTML::Template::Expr, "
                "not loaded by LoxBerry. Use stock TMPL_IF NAME with a boolean param."
            ))
        # Any user-supplied value MUST be ESCAPE=HTML — guard against XSS.
        for m in re.finditer(r"<TMPL_VAR\s+[^>]*NAME\s*=\s*\"([^\"]+)\"([^>]*)>", text, re.IGNORECASE):
            attrs = m.group(2)
            name = m.group(1)
            if "ESCAPE" not in attrs.upper():
                issues.append(warn(
                    f"{rel}: <TMPL_VAR NAME=\"{name}\"> has no ESCAPE attribute — "
                    "use ESCAPE=HTML unless intentionally rendering trusted markup."
                ))

    # default.json sanity: never ship plaintext credentials.
    cfgfile = root / "config" / "default.json"
    if cfgfile.exists():
        try:
            import json as _json
            cfg = _json.loads(cfgfile.read_text(encoding="utf-8-sig"))
            for key in ("password", "mqtt_password", "api_key", "token", "secret"):
                if cfg.get(key):
                    issues.append(fail(
                        f"config/default.json ships a non-empty {key!r} — "
                        "credentials must be empty in the template, the user fills them in."
                    ))
        except Exception as err:
            issues.append(warn(f"could not parse config/default.json: {err}"))

    # dpkg/apt should declare paho-mqtt as a Debian package, not in requirements.txt.
    apt_file = root / "dpkg" / "apt"
    req_file = root / "requirements.txt"
    daemons_use_paho = any("paho" in (root / "bin" / d.name).read_text(encoding="utf-8", errors="replace")
                            for d in daemon_files)
    if daemons_use_paho:
        if not apt_file.exists() or "python3-paho-mqtt" not in apt_file.read_text(encoding="utf-8", errors="replace"):
            issues.append(fail(
                "daemon imports paho-mqtt but dpkg/apt does not declare python3-paho-mqtt — "
                "LoxBerry installer ignores requirements.txt."
            ))

    return issues


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print("Usage: validate_plugin.py <generated-plugin-root>")
        return 2

    root = Path(argv[1]).resolve()
    issues: list[str] = []

    if not root.exists() or not root.is_dir():
        print(fail(f"not a directory: {root}"))
        return 1

    for rel in REQUIRED_FILES:
        if not (root / rel).exists():
            issues.append(fail(f"missing required file: {rel}"))

    if (root / "plugin.cfg").exists():
        issues.extend(validate_plugin_cfg(root))

    plugin_name = ""
    cfg_path = root / "plugin.cfg"
    if cfg_path.exists():
        parser = configparser.ConfigParser()
        parser.optionxform = str
        parser.read(cfg_path, encoding="utf-8-sig")
        if parser.has_section("PLUGIN"):
            plugin_name = parser["PLUGIN"].get("NAME", "").strip()

    issues.extend(validate_text(root, plugin_name))

    for issue in issues:
        print(issue)

    failed = any(issue.startswith("FAIL:") for issue in issues)
    if failed:
        return 1

    print("PASS: generated LoxBerry plugin repository passed required checks")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
