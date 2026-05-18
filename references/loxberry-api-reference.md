# LoxBerry API and System Reference

Use this reference when generating LoxBerry plugin code, metadata, daemon wrappers, runtime paths, release manifests, or Loxone setup docs.

## Runtime Path Variables

Use LoxBerry-provided environment variables. Do not hardcode production paths in generated code.

| Variable | Purpose | Typical path |
|---|---|---|
| `LBHOMEDIR` | LoxBerry installation root | `/opt/loxberry` |
| `LBPBINDIR` | Plugin executables | `/opt/loxberry/bin/plugins/{plugin}` |
| `LBPCONFIGDIR` | Plugin configuration | `/opt/loxberry/config/plugins/{plugin}` |
| `LBPDATADIR` | Plugin persistent data | `/opt/loxberry/data/plugins/{plugin}` |
| `LBPLOGDIR` | Plugin logs | `/opt/loxberry/log/plugins/{plugin}` |
| `LBPTEMPLATEDIR` | Plugin templates | `/opt/loxberry/templates/plugins/{plugin}` |
| `LBPHTMLAUTHDIR` | Authenticated web UI | `/opt/loxberry/webfrontend/htmlauth/plugins/{plugin}` |
| `LBPHTMLDIR` | Public web UI | `/opt/loxberry/webfrontend/html/plugins/{plugin}` |

Python fallback pattern for local development:

```python
from pathlib import Path
import os

PLUGIN_NAME = "example-plugin"
CONFIG_DIR = Path(os.environ.get("LBPCONFIGDIR", f"./config"))
LOG_DIR = Path(os.environ.get("LBPLOGDIR", f"./logs"))
```

Fallbacks must be development-friendly, not production assumptions.

## Core Libraries

Use the native LoxBerry libraries for web UI and platform integration when writing Perl or PHP.

| Language | Library | Use |
|---|---|---|
| Perl | `LoxBerry::System` | Paths, plugin metadata, Miniserver settings |
| Perl | `LoxBerry::Web` | Authenticated UI header/footer helpers |
| Perl | `LoxBerry::Log` | Structured log integration |
| Perl | `LoxBerry::JSON` | Read/write JSON configuration |
| Perl | `LoxBerry::IO` | MQTT and Miniserver helper functions where available |
| PHP | `loxberry_system.php` | Runtime constants |
| PHP | `loxberry_web.php` | UI helpers |
| PHP | `loxberry_log.php` | Logging |
| PHP | `loxberry_io.php` | MQTT and Miniserver helper functions |

Python daemon code can use standard libraries plus explicit dependencies such as `paho-mqtt`, `requests`, or `pymodbus`. Document every non-standard dependency in the generated README.

## plugin.cfg

Required minimum:

```ini
[AUTHOR]
NAME=Author Name
EMAIL=author@example.com

[PLUGIN]
VERSION=0.1.0
NAME=example-plugin
FOLDER=example-plugin
TITLE=Example Plugin

[AUTOUPDATE]
AUTOMATIC_UPDATES=true
RELEASECFG=https://raw.githubusercontent.com/{owner}/{repo}/main/release.cfg
PRERELEASECFG=https://raw.githubusercontent.com/{owner}/{repo}/main/prerelease.cfg

[SYSTEM]
LB_MINIMUM=3.0.0
REBOOT=false
ARCHITECTURE=""
CUSTOM_LOGLEVELS=true
```

Rules:

- `NAME` and `FOLDER` are immutable after public release.
- `NAME` and `FOLDER` must be lowercase ASCII and may contain digits and hyphens.
- `VERSION` must use semantic versioning.
- Keep `REBOOT=false` unless the plugin truly changes system-level state.
- Use empty `ARCHITECTURE` unless the plugin depends on hardware-specific binaries.

## release.cfg

```ini
[AUTOUPDATE]
VERSION=0.1.0
ARCHIVEURL=https://github.com/{owner}/{repo}/archive/refs/tags/v0.1.0.zip
```

Generate `prerelease.cfg` with the same format when pre-release updates are enabled. The version in `release.cfg` should match the public release tag.

## Daemon Lifecycle

LoxBerry installs the daemon hook at `/opt/loxberry/system/daemons/plugins/<folder>` (file mode 755, owner root). It is invoked **twice** in two different contexts and the wrapper must handle both:

1. **At system boot, by `/etc/systemd/system/loxberry.service`, with NO arguments and as root.** No `LBPBINDIR`/`LBPCONFIGDIR`/`LBPLOGDIR` are exported — derive them from a hardcoded plugin folder name + `LBHOMEDIR` (default `/opt/loxberry`). Reference: `/opt/loxberry/system/daemons/system/50-mqttgateway` is two lines: `su loxberry -c "$LBHOMEDIR/sbin/mqttgateway.pl > /dev/null 2>&1 &"`.
2. **At runtime from the plugin's web UI**, when the CGI calls `system("/opt/loxberry/system/daemons/plugins/<folder>", "restart")`. The CGI runs as the `loxberry` user under Apache, so `su loxberry -c ...` will fail (no PAM session for non-root). Detect `id -un` and skip the `su` when already running as the daemon user.

Generated daemon wrappers must:

- Treat **no arguments** as `start` — i.e. `case "${1:-start}" in`. Anything else is the SysV-style `start|stop|restart|status` interface.
- Not crash on unbound LoxBerry env vars at boot. Derive paths: `LBHOMEDIR="${LBHOMEDIR:-/opt/loxberry}"; LBPBINDIR="$LBHOMEDIR/bin/plugins/$PLUGINNAME"; LBPLOGDIR="$LBHOMEDIR/log/plugins/$PLUGINNAME"; …` Export those before launching the daemon binary so the daemon sees the same paths regardless of who invoked it.
- Drop privileges with `su "$DAEMON_USER" -c "..."` when running as root; fork directly when already running as `DAEMON_USER` (id -un check). The default `DAEMON_USER` is `loxberry`.
- Write the pidfile under `LBPLOGDIR` (writable by `loxberry`), **never** `/run/` (requires root).
- After forking the daemon, wait ~1 s and verify it's still alive. If the daemon fast-exited (missing config, crash on dependency), **remove the pidfile** and exit non-zero. Otherwise the next `status` call will report "stopped (stale pidfile)" forever.
- Send `SIGTERM` first on `stop`, wait up to 5 s, then `SIGKILL`.
- Start the actual daemon from `$LBPBINDIR/<plugin>.py` (or equivalent), redirecting stdout/stderr to a log file under `$LBPLOGDIR`.

The Python/Perl daemon itself must:

- Handle `SIGTERM` and `SIGINT` cleanly via signal handlers.
- **Soft-exit 0 with a clear log message** when mandatory config is missing (e.g. account credentials not yet entered by the user). Do NOT raise/exit 1 — that creates noise on every boot until the user opens the plugin page.
- Catch exceptions inside the polling loop so a single failed cycle does not kill the daemon.

Use `assets/daemon.template` as the baseline wrapper (already implements the two-invocation contract above).

## Python and System Dependencies

LoxBerry installs apt packages declared in `<plugin>/dpkg/apt` (one Debian package name per line, no version pinning). The installer runs `apt-get install -y` for each line at plugin install time.

- Python deps must be expressed as Debian packages here, e.g. `python3-paho-mqtt`, `python3-requests`. Do **not** rely on `requirements.txt` or `pip install` — neither is processed by the LoxBerry installer.
- Use `<plugin>/dpkg/apt<lbversionmajor>` (e.g. `apt3`) or `<plugin>/dpkg/apt<debian_version>` (e.g. `apt12`) for version-specific lists when needed. The base `apt` file is always read as a fallback.
- For pre/post install scripting beyond `apt`, ship `preinstall.sh` / `postinstall.sh` in the plugin root.

## Installer behaviour and configuration persistence

`/opt/loxberry/sbin/plugininstall.pl` is the canonical install/upgrade/uninstall driver. Things to know that have bitten this skill before:

- **`config/*` is overwritten on every install/upgrade.** The relevant call is `cp -r $tempfolder/config/* $lbhomedir/config/plugins/$pfolder` with no `is_upgrade` guard. User-edited config files are wiped. Two patterns cope with this:
  1. Ship `config/default.json` as a template with empty credential fields; accept that the user must re-enter once after each upgrade. Easiest, what most LoxBerry plugins do.
  2. Split into `config/defaults.json` (template, gets overwritten — fine) and `config/user.json` (NOT shipped with the plugin, only created on save — installer never sees it, preserved across upgrades). The daemon/CGI merge both on load.
- **`bin/`, `templates/`, `webfrontend/htmlauth/`, `daemon/`, `dpkg/`, `data/system/install/` are all overwritten** as well — this is correct for code.
- **CGI files come out non-executable on some installs**: `plugininstall.pl`'s permission-fix step runs `find` from `/root` (which the `loxberry` user cannot read), so `find: Failed to change directory: /root` aborts the chmod, and `<lbphtmlauthdir>/index.cgi` stays at `0644`. Apache then returns 500 on the plugin page. Mitigation: ship a `postinstall.sh` that does `chmod 0755 webfrontend/htmlauth/plugins/<plugin>/index.cgi`, or document the manual fix.
- **CLI invocation is CGI-style** — `plugininstall.pl action=install file=/path/to.zip pin=1234` (positional `name=value` pairs from `CGI::Vars`, NOT `--action=…`). Requires `PERL5LIB=/opt/loxberry/libs/perllib`.
- **SecurePIN is stored at `/opt/loxberry/config/system/securepin.dat`** as a single-line classical `crypt()` hash (DES, 13 chars, 2-char salt). The default after a fresh sandbox install is `IGiEHzNfbqDhk` (which is NOT `crypt("1234", "IG")`). To force a known PIN for scripted installs: `perl -e 'print crypt(q{1234}, q{IG})' > /opt/loxberry/config/system/securepin.dat` then `chmod 0600 + chown loxberry:loxberry`. Validation runs via `LoxBerry::System::check_securepin($pin)` which shells out to `credentialshandler.pl`.
- **Plugin registry** lives at `/opt/loxberry/data/system/plugindatabase.json` (JSON). Each entry is keyed by an MD5-derived `pid` and includes the resolved `directories` (`lbpbindir`, `lbpconfigdir`, …), the `files` (daemon, sudoers, uninstall hook), the `version`, `interface`, etc. Query/inspect to confirm a plugin is registered:

  ```bash
  cat /opt/loxberry/data/system/plugindatabase.json | python3 -m json.tool
  ```

## MQTT broker discovery (LoxBerry 3.x)

LoxBerry 3.0 ships its own `mosquitto` broker on `localhost:1883` plus a built-in MQTT Gateway daemon (`/opt/loxberry/sbin/mqttgateway.pl`). Plugins should auto-discover the broker credentials rather than asking the user for them.

- **Credentials live in** `/opt/loxberry/config/system/general.json` under the `Mqtt` key:

  ```json
  "Mqtt": {
    "Brokerhost": "localhost", "Brokerport": "1883",
    "Brokeruser": "loxberry",  "Brokerpass": "<auto-generated-per-install>",
    "Udpinport":  "11884",     "Websocketport": "9001",
    "Uselocalbroker": "1",     "Finderdisabled": false
  }
  ```

- **Perl helper** (use from the CGI to render the auto-discovered preview line):
  `my $cred = LoxBerry::IO::mqtt_connectiondetails();` returns a hashref with `brokerhost`, `brokerport`, `brokeruser`, `brokerpass`, `brokeraddress`, `websocketport`, `udpinport`.
- **Python equivalent**: read `general.json` directly with stdlib `json`. See the snippet in `integration-patterns.md → MQTT Bridge → Broker credential auto-discovery`.
- **MQTT Gateway subscription registration**: write `<lbpconfigdir>/mqtt_subscriptions.cfg` (one MQTT topic-pattern per line). `mqttgateway.pl` watches every installed plugin's config dir with inotify and merges these into its active subscription list automatically — no manual subscription step in the Gateway UI.
- **The standalone *MQTT Gateway* plugin by `christianTF`** is blocked on LoxBerry 3.0 and exists only for 2.x systems. Do not require it as a dependency.

## Miniserver Communication

### MQTT Gateway

Recommended for most integrations.

Flow:

1. Plugin publishes to local Mosquitto on `localhost:1883`.
2. MQTT Gateway sees the topic in Incoming Overview.
3. User converts the topic to a Miniserver Virtual Input.
4. Loxone Config contains a Virtual Input with the exact mapped name.

Generated docs must include the complete topic list and matching Virtual Input names.

### HTTP REST

Use only when MQTT Gateway is unavailable or when controlling Miniserver objects directly.

Example:

```text
GET http://{user}:{password}@{miniserver_ip}/dev/sps/io/{control}/{value}
```

Do not recommend putting real passwords in screenshots, examples, logs, or repository files.

### UDP

Use for existing UDP workflows or high-frequency payloads.

Document:

- Listener port.
- Sender address expected by Loxone.
- Payload format.
- Parsing assumptions.
- How to use UDP Monitor in Loxone Config.

## Reserved Ports

Avoid binding plugin listeners to common LoxBerry or network service ports.

| Port | Service |
|---:|---|
| 80 | Web UI |
| 443 | HTTPS |
| 1883 | MQTT |
| 8883 | MQTT over TLS |
| 9001 | MQTT WebSocket |
| 1900 | UPnP/SSDP |
| 5353 | mDNS |

Prefer documented plugin ports above `9100` when a listener is required.

## Security and Reliability

- Treat API keys, passwords, tokens, and OAuth refresh tokens as secrets.
- Mask secrets in logs and web UI.
- Use explicit network timeouts.
- Validate user-entered hostnames, URLs, ports, and polling intervals.
- Keep default polling conservative.
- Back off after network or authentication failures.
- Do not busy-loop when a device is offline.
- Make destructive commands opt-in and visible in generated docs.
