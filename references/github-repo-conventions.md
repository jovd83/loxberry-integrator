# GitHub repository conventions for LoxBerry plugins

Every LoxBerry plugin repository follows the layout of the canonical reference,
[jovd83/LoxBerry-Plugin-mammotion-mower](https://github.com/jovd83/LoxBerry-Plugin-mammotion-mower).
Read this before step 3 and step 6 of the Mandatory Final Steps.

1. **README opening.** A short title, then one paragraph on what the plugin bridges into the Loxone Miniserver:
   cloud/API → MQTT, MQTT Gateway integration, command flow.
2. **Badges** directly under the title, in this order: LoxBerry compatibility (e.g. `LoxBerry 3.0+`), License,
   Version.
3. **README sections**, in this order: *What it does*, *Screenshots* (annotated PNGs under `screenshots/`),
   *Requirements*, *Installation* (links to the GitHub Releases page and the install ZIP), then plugin-specific
   sections such as MQTT topics, configuration and troubleshooting.
4. **Repository topics:** always `loxberry`, `loxberry-plugin`, `loxone`, `home-automation`, `smart-home`, plus
   device or protocol topics (e.g. `mqtt`, `mammotion`, `robot-mower`).
5. **Validation workflow** at `.github/workflows/validate.yml`, on push and pull_request: lint `plugin.cfg` and
   `release.cfg`, and validate the ZIP structure.
6. **GitHub Releases are mandatory.** Each tagged release attaches the installable `<plugin-name>-<version>.zip`
   that LoxBerry's Plugin Install consumes.
7. **CHANGELOG.md** in Keep a Changelog / semver form, so release-manager-skill's changelog gate works.
8. **LICENSE** at the repo root. Default to MIT, but match the license that third-party dependencies require
   (e.g. PyMammotion → Apache-2.0, GPL-derived libraries → GPL) and explain the choice in the README. The
   reference repo uses Apache-2.0 because of PyMammotion.

Publishing (commit, push, tag, release) goes through `release-manager-skill`, never a raw `git push`, so the
install ZIP is produced from a GitHub Release.

*Source: the `LoxBerryPluginConventions` entry of the retired shared-memory ledger (user decision, 2026-05-27).*
