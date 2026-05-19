# LoxBerry Integrator AgentSkill

[![Validate Skills](https://github.com/jovd83/loxberry-integrator/actions/workflows/ci.yml/badge.svg)](https://github.com/jovd83/loxberry-integrator/actions/workflows/ci.yml)
[![version](https://img.shields.io/badge/version-0.1.0-blue)](CHANGELOG.md)
[![license](https://img.shields.io/badge/license-MIT-green)](LICENSE)
[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-ffdd00?style=flat&logo=buy-me-a-coffee&logoColor=black)](https://buymeacoffee.com/jovd83)

`loxberry-integrator` is an agentSkill that generates, reviews, and hardens GitHub-ready LoxBerry plugin repositories for Loxone Miniserver integrations.

It is designed for integrations such as cloud API bridges, local REST gateways, MQTT topic mappers, UDP relays, Modbus TCP polling plugins, and command bridges from Loxone to external services.

## What This Skill Owns

- Gathering an integration brief from a user.
- Selecting an appropriate LoxBerry/Loxone integration pattern.
- Generating installable plugin repository structure.
- Producing `plugin.cfg`, release manifests, daemon scaffolding, web UI templates, config defaults, README, license, and Loxone Config docs.
- Enforcing naming, path, MQTT topic, credential, and validation conventions.
- Validating generated plugin repositories with `scripts/validate_plugin.py`.

## What This Skill Does Not Own

- Managing live LoxBerry or Loxone systems.
- Storing shared cross-agent memory.
- Installing packages on a user's LoxBerry instance.
- Guaranteeing device-specific APIs without vendor documentation or user-provided examples.

## Structure

```text
loxberry-integrator/
  SKILL.md
  agents/openai.yaml
  assets/
  examples/
  references/
  scripts/
```

`SKILL.md` contains the core workflow. Detailed LoxBerry platform rules and integration patterns live in `references/` so agents can load them only when needed. Reusable plugin file templates live in `assets/`.

## Installation

```bash
npx skills install jovd83/loxberry-integrator
```

This drops the skill into your AgentSkills directory under the folder
name `loxberry-integrator` (the name is load-bearing — do not rename).

Manual alternative: clone or download the repo and place the folder in
your Codex / AgentSkills skills directory. The required skill entry
point is `SKILL.md`.

## Testing in a sandbox (dockerized LoxBerry)

The skill is built around a no-touch test loop: after generating a
plugin it installs it into a real, running LoxBerry and iterates until
the daemon publishes data cleanly. The sandbox is a **dockerized
LoxBerry 3.0.x** (image: [`boernmasta/loxberry`](https://hub.docker.com/r/boernmasta/loxberry),
DietPi-based, amd64) — no VirtualBox / Hyper-V / VM hypervisor needed.

The compose file ships in `sandbox/tools/docker-compose.yml`. SKILL.md
encodes a **conditional** bootstrap that runs before any plugin
testing:

```bash
# 1. Check current state — skip the rest if the container is already Up.
docker ps --filter name=loxberry-sandbox --format '{{.Names}} {{.Status}}'

# 2a. If a stopped container exists — just start it.
docker compose -f sandbox/tools/docker-compose.yml start

# 2b. If no container exists at all — pull + create.
cd sandbox/tools && docker compose pull && docker compose up -d
```

The first `docker compose pull` is ~1.1 GB. After that, every run of
the skill against a new plugin reuses the same container (state is
persisted in named volumes — `docker compose down -v` is the only
thing that wipes credentials/plugin installs).

Once the sandbox is up, the skill installs the freshly-built plugin
via the official LoxBerry installer, watches the daemon log + MQTT
topics, and rebuilds → reinstalls until the daemon runs cleanly and
data flows to the (in-container) MQTT broker as designed. See SKILL.md
→ *Mandatory Final Steps → Sandbox bootstrap (conditional)* and
*Test in the sandbox* for the full procedure, including the CLI
install command, the SecurePIN seeding step, and the verification
recipe.

> **Requirements**: Docker Desktop running on the host (Windows /
> macOS / Linux). The compose file sets `privileged: true` and
> `cgroup: host` because the LoxBerry image runs systemd inside —
> without those flags the container exits 255 in under a second.

The deprecated **VirtualBox** alternative under
`sandbox/tools/build-loxberry-vm.ps1` is kept for reference only —
use the Docker path unless the task specifically requires a real
LAN-attached LoxBerry host (e.g. Loxone Miniserver auto-discovery).

## Validation

Validate the skill metadata with the AgentSkill validator available in your Codex environment, for example:

```bash
python C:/Users/jochi/.codex/skills/.system/skill-creator/scripts/quick_validate.py .
```

Validate a generated plugin repository:

```bash
python scripts/validate_plugin.py path/to/LoxBerry-Plugin-example
```

## Optional Integrations

Shared memory is intentionally out of scope. If an organization wants reusable device profiles or house standards across agents, integrate this skill with an external shared-memory workflow and promote only stable, reviewed knowledge.

## License

MIT — see [LICENSE](LICENSE).
