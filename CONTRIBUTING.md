# Contributing

Contributions should make generated LoxBerry plugins clearer, safer, more installable, or easier to validate.

## Guidelines

- Keep `SKILL.md` concise and procedural.
- Put detailed platform knowledge in `references/`.
- Put reusable generated-plugin files in `assets/`.
- Avoid speculative abstractions and placeholder frameworks.
- Keep examples realistic and device-specific enough to test the workflow.
- Do not add behavior that stores credentials or promotes memory automatically.

## Validation Before PR

Run:

```bash
python C:/Users/jochi/.codex/skills/.system/skill-creator/scripts/quick_validate.py .
python scripts/validate_plugin.py <sample-generated-plugin>
```

If you cannot run the generated-plugin validator, document why and include the generated repository tree in the PR notes.
