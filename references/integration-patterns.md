# LoxBerry Integration Patterns

Use this reference to choose and implement the generated plugin architecture.

## Pattern Selection

| Pattern | Choose when | Main risks |
|---|---|---|
| `mqtt-bridge` | The source is a cloud API, local API, or normal polling integration | Rate limits, auth expiry, topic drift |
| `rest-gateway` | A LAN device exposes simple HTTP JSON endpoints | Timeouts, schema changes |
| `modbus-tcp` | Device exposes Modbus TCP registers | Register offsets, byte order, connection drops |
| `udp-relay` | Device sends or requires UDP datagrams | Packet loss, parsing ambiguity |
| `command-bridge` | Loxone must control an external device | Auth, idempotency, command confirmation |

Prefer MQTT Gateway as the bridge into Loxone for generated sensor values.

## Shared Daemon Requirements

All generated daemons should:

- Read config from `LBPCONFIGDIR/default.json`.
- Write logs under `LBPLOGDIR`.
- Handle `SIGTERM` and `SIGINT`.
- Use explicit timeouts.
- Use bounded exponential backoff.
- Publish stable data point names.
- Redact secrets in logs.
- Exit non-zero on unrecoverable configuration errors.

Python helper shape:

```python
def backoff_sleep(base_seconds, attempt, maximum_seconds=300):
    delay = min(base_seconds * (2 ** attempt), maximum_seconds)
    time.sleep(delay)
```

## MQTT Bridge

Use for cloud APIs, local REST APIs, and most new integrations.

Flow:

```text
External service/device -> LoxBerry daemon -> MQTT localhost:1883 -> built-in MQTT Gateway -> Miniserver Virtual Inputs
```

> **LoxBerry 3.0 ships its own MQTT broker (`mosquitto` on `localhost:1883`) and its own MQTT Gateway** (`/opt/loxberry/sbin/mqttgateway.pl`, managed by `/opt/loxberry/system/daemons/system/50-mqttgateway`). The standalone *MQTT Gateway* plugin by `christianTF` is **blocked on LB 3.x** and exists only for legacy 2.x systems — do not list it as a dependency in a new plugin.

### Broker credential auto-discovery (LB 3.x)

LoxBerry exposes the broker host/port/user/pass through `LoxBerry::IO::mqtt_connectiondetails()`. The same data lives in `/opt/loxberry/config/system/general.json` under the `Mqtt` key (`Brokerhost`, `Brokerport`, `Brokeruser`, `Brokerpass`, `Udpinport`, `Websocketport`). The recommended UX is a **"Use the built-in LoxBerry MQTT broker"** checkbox that is **checked by default** — the user enters their upstream-service credentials only, never broker credentials.

Python (in the daemon — stdlib `json`, no Perl bridge needed):

```python
def load_loxberry_mqtt_creds():
    """Read broker host/port/user/pass from LoxBerry's general.json.
    Returns None when the file is absent or has no Mqtt section."""
    path = Path(os.environ.get("LBSCONFIG") or "/opt/loxberry/config/system") / "general.json"
    try:
        with path.open(encoding="utf-8-sig") as fh:
            mqtt = json.load(fh).get("Mqtt") or {}
    except (OSError, json.JSONDecodeError):
        return None
    if not (mqtt.get("Brokerhost") and mqtt.get("Brokerport")):
        return None
    return {
        "host": str(mqtt["Brokerhost"]),
        "port": int(mqtt["Brokerport"]),
        "username": mqtt.get("Brokeruser") or "",
        "password": mqtt.get("Brokerpass") or "",
    }
```

Perl (in the CGI — to render the auto-discovered preview line on the plugin page):

```perl
eval {
    require LoxBerry::IO;
    my $cred = LoxBerry::IO::mqtt_connectiondetails();
    if ($cred && $cred->{brokerhost}) {
        $lb_mqtt_host = $cred->{brokerhost};
        $lb_mqtt_port = $cred->{brokerport};
        $lb_mqtt_user = $cred->{brokeruser} || "";
        $lb_mqtt_available = 1;
    }
};
```

Always keep the manual `mqtt_host` / `mqtt_port` / `mqtt_username` / `mqtt_password` fields as a fallback for users who run a non-LoxBerry broker, but **hide them behind the checkbox in the UI** so the common path is zero-config.

### Topic subscription auto-registration

LoxBerry 3.0's built-in `mqttgateway.pl` watches every installed plugin's config directory with inotify and merges the contents of `<lbpconfigdir>/mqtt_subscriptions.cfg` (one MQTT topic pattern per line) into its active subscription list. **The plugin should write this file itself** on every daemon start — the user should not need to manually paste the topic prefix into MQTT Gateway settings.

```python
def register_mqtt_subscription(prefix: str) -> None:
    """Drop a single-line mqtt_subscriptions.cfg into LBPCONFIGDIR so the
    built-in MQTT Gateway relays <prefix>/# to the Loxone Miniserver as
    Virtual Inputs. The gateway picks the change up within seconds via
    inotify — no daemon restart needed."""
    if not CONFIG_DIR.exists():
        return  # running outside LoxBerry
    target = CONFIG_DIR / "mqtt_subscriptions.cfg"
    body = f"{prefix}/#\n"
    if target.exists() and target.read_text(encoding="utf-8") == body:
        return  # already up to date — avoid retriggering inotify
    target.write_text(body, encoding="utf-8")
```

Expose this behind a `register_mqtt_subscription: true` config key (checkbox on the plugin page, default on). Users who run their own MQTT-to-Loxone relay can turn it off; everyone else gets Virtual Inputs in Loxone with no additional configuration step.

### Implementation notes

- Use `paho-mqtt` (Debian package: `python3-paho-mqtt` — declare in `dpkg/apt`, NOT in `requirements.txt`).
- `paho-mqtt` 1.x → 2.x changed the constructor signature. Be forward-compatible:

  ```python
  client_kwargs = {}
  if hasattr(mqtt, "CallbackAPIVersion"):
      client_kwargs["callback_api_version"] = mqtt.CallbackAPIVersion.VERSION2
  client = mqtt.Client(**client_kwargs)
  ```

- Make `mqtt_topic_prefix` configurable. **Sanitize it** through a regex on load — the user can type anything in the field, but MQTT topics cannot contain `#`, `+`, `/`, whitespace, NUL, etc.:

  ```python
  TOPIC_SEGMENT_RE = re.compile(r"[^A-Za-z0-9_.-]+")
  prefix = TOPIC_SEGMENT_RE.sub("_", str(prefix).strip().strip("/"))
  ```

- Retain sensor values unless the value is event-only.
- Publish plugin-wide health to `{prefix}/_status` (`online` / `error` / `offline`), `{prefix}/_device_count`, `{prefix}/_last_poll_epoch`.
- Use `{prefix}/{device_id}/{datapoint}` for per-device values; `{device_id}` should derive from a stable serial (`sn`) when available, with `devid` / `mac` as fallbacks.

Minimal publish helper:

```python
def publish_value(client, prefix, device_id, datapoint, value):
    safe_device   = TOPIC_SEGMENT_RE.sub("_", str(device_id)).strip("_").lower() or "device"
    safe_datapoint = TOPIC_SEGMENT_RE.sub("_", str(datapoint)).strip("_") or "value"
    topic = f"{prefix}/{safe_device}/{safe_datapoint}"
    client.publish(topic, str(value), retain=True)
    return topic
```

## REST Gateway

Use when a device exposes a local HTTP API or a cloud API is the source of truth.

Implementation notes:

- Use `requests.Session`.
- Set connect/read timeouts.
- Handle `401`, `403`, `429`, and `5xx` distinctly.
- Keep API URL, auth method, and polling interval in config.
- Avoid logging full URLs if credentials may appear in query strings.

Generated config should include:

```json
{
  "api_url": "https://example.invalid/api/status",
  "auth_type": "api_key",
  "api_key": "",
  "poll_interval_seconds": 60,
  "timeout_seconds": 10
}
```

## Modbus TCP

Use for energy meters, inverters, heat pumps, and industrial sensors.

Implementation notes:

- Use a persistent client when possible.
- Reconnect with backoff after failures.
- Make register maps declarative in `default.json`.
- Document zero-based vs one-based register addressing.
- Expose byte order and word order.
- Include unit and scale for every data point.

Register map shape:

```json
{
  "device_ip": "192.168.1.50",
  "device_port": 502,
  "slave_id": 1,
  "poll_interval_seconds": 10,
  "byte_order": "big",
  "word_order": "big",
  "registers": [
    {
      "name": "grid_power",
      "address": 0,
      "count": 2,
      "type": "int32",
      "unit": "W",
      "scale": 1
    }
  ]
}
```

## UDP Relay

Use when the device already speaks UDP or when the Miniserver configuration is explicitly UDP-based.

Flow:

```text
UDP device -> LoxBerry daemon parser -> Miniserver Virtual UDP Input
```

Implementation notes:

- Bind to a documented port above `9100`.
- Set socket timeouts so shutdown can complete.
- Parse payloads defensively.
- Include examples of valid payloads in docs.
- Prefer MQTT publication after parsing unless direct UDP to Miniserver is required.

## Command Bridge

Use for outbound control from Loxone to an external device or service.

Supported shapes:

- Authenticated `index.cgi` endpoint in LoxBerry web UI.
- MQTT command topic such as `{plugin}/main/set/{command}`.
- Poll-and-apply queue stored in plugin-local config or data.

Rules:

- Validate command names and values against an allowlist.
- Make commands idempotent where possible.
- Log command outcomes without secrets.
- Return clear HTTP status and plain-text or JSON responses.
- Document whether commands are fire-and-forget or confirmed by device state.
