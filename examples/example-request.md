# Example Request

Use this request to forward-test the skill on a realistic plugin generation task.

```text
Create a LoxBerry plugin for a Fronius solar inverter.

The inverter is reachable on the LAN at 192.168.1.77 and exposes JSON over HTTP.
Poll every 30 seconds and publish these values to Loxone through MQTT Gateway:

- grid_power_w
- pv_power_w
- battery_soc_percent
- self_consumption_percent

Use Python for the daemon. The GitHub repository will be acme-home/loxberry-fronius-bridge.
```

Expected high-level outcome:

- Pattern: `rest-gateway` with MQTT Gateway output.
- Repository includes `plugin.cfg`, release manifests, daemon wrapper, Python daemon, config, authenticated web UI, README, license, and Loxone Config docs.
- MQTT topics follow `{plugin}/main/{datapoint}`.
- Generated docs explain MQTT Gateway conversion and exact Virtual Input names.
