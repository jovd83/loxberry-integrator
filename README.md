# LoxBerry Integrator AgentSkill

`loxberry-integrator` helps Codex generate, review, and harden GitHub-ready LoxBerry plugin repositories for Loxone Miniserver integrations.

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

Place this folder in your Codex/AgentSkills skills directory and ensure the folder name remains `loxberry-integrator`.

The required skill entry point is:

```text
SKILL.md
```

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

Apache License 2.0.
