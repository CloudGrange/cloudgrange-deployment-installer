# cloudgrange-deployment-installer — Agent instructions

<!--
  AGENTS.md is the canonical, cross-tool instruction file for this repo.
  Codex CLI, Cursor, and VS Code Copilot read it natively; Claude Code
  imports it via CLAUDE.md; Gemini reads it via contextFileName.
  Keep it THIN — it is a bootstrap and an offline fallback, not a full
  standards library. The authoritative source is the HCS Governance MCP.
-->

## What this repo is

PowerShell automation repo. Contains scripts and modules that manage Azure Local and supporting infrastructure. All scripts target PowerShell 7 and follow HCS scripting standards.

<!-- One paragraph. What the repo is, why it exists, and what it is not. -->

---

## Start here — connect to the HCS Governance MCP

This repo is governed by the **HCS Governance MCP server** (connection details in
[`.ai/mcp/mcp-servers.md`](.ai/mcp/mcp-servers.md)). It is the source of truth for
standards, hard rules, and orchestration guidance.

**At session start, call:**

```
bootstrap(repo="cloudgrange-deployment-installer", client="<your client: claude-code | codex | gemini | cursor | vscode>")
```

It returns this repo's scope, the applicable hard rules, the index of applicable
standards, the `.ai/` session protocol, and orchestration guidance shaped for your
client's capability tier. **Prefer a live MCP answer over anything written in this file** —
this file is the offline fallback.

---

## Offline fallback (when the MCP server is unreachable)

**Standards scope:** `hcs` <!-- hcs | tierpoint-prodtech | azurelocal -->

**Hard rules digest:**

- No secrets, tokens, passwords, subscription/tenant/client IDs, or connection strings in any committed file.
- All scripts: PowerShell 7+ — `#Requires -Version 7.0`, `Set-StrictMode -Version Latest`, `$ErrorActionPreference = 'Stop'`. Never PS 5.1, never Bash.
- All documentation is Markdown only. Diagrams are draw.io only — commit the `.drawio` XML alongside any exported `.png`.
- Commit format: `type(scope): short description` — types `feat`, `fix`, `docs`, `chore`, `refactor`, `test` — with an `AB#<id>` work-item reference.

**Standards reference (public site — no auth required):**

- Governance — <https://platform.hybridsolutions.cloud/standards/governance/>
- Scripting — <https://platform.hybridsolutions.cloud/standards/scripting/>
- Automation — <https://platform.hybridsolutions.cloud/standards/automation/>
- Documentation — <https://platform.hybridsolutions.cloud/standards/documentation/>
- Agents (multi-model) — <https://platform.hybridsolutions.cloud/standards/agents/>
- AI workspace — <https://platform.hybridsolutions.cloud/standards/ai-workspace/>
- Full index — <https://platform.hybridsolutions.cloud/standards/>

---

## Merge gate — all tests must pass

`sudo -E scripts/test-all.sh` is the gate. Run it before every merge; it must exit 0.

- It runs: the pinning gate, the compose-hardening and ssh-transport gates, every python release-gate suite under `test/appliance` (as root, nothing skipped), and the PowerShell source qualification (parser + PSScriptAnalyzer + release-BOM schema, which itself runs `test/Invoke-InstallerPester.ps1` with `-RequireNoSkipped`). That last one runs in a `mcr.microsoft.com/powershell` container as a non-root user with passwordless sudo — WSL has no pwsh, and as root five Pester tests skip themselves. On Windows, run that script directly with pwsh 7.
- Prerequisites: root, a reachable Docker engine with the compose plugin, PyYAML, and network access to the PowerShell Gallery. `CLOUDGRANGE_TEST_ALLOW_SKIP` is for a developer's own machine and must never be set for the gate — the gate refuses to run with it set, because it turns a missing prerequisite into a skipped release gate.
- It exits non-zero on ANY failing test, build error or skipped test, and if no tests ran at all.
- **All tests must pass; there is no "pre-existing failure" exemption.** A red test on main is a
  bug to fix at its root (product bug, test bug, missing test infrastructure, or real flakiness),
  never a reason to merge on top of it. Do not skip, delete or weaken a test to go green unless it
  is truly obsolete, and say why in the PR.
- There are no GitHub Actions test runs (the owner pays for minutes): the gate runs locally, in WSL.
- The gate is a bash script by design (an exception to the PowerShell-only scripting rule): it runs
  where the tests run, on Linux/WSL.

## Session protocol

1. **Read `.ai/state/` first** — `CURRENT_TASK.md`, then `HANDOFF.md`, then `OPEN_QUESTIONS.md`.
2. Then read `.ai/memory/` for durable context (`PROJECT_CONTEXT.md`, `DECISIONS.md`, `COMMANDS.md`, `GOTCHAS.md`).
3. Summarise your believed state back to the operator before making changes.
4. **Before ending the session, update `.ai/state/HANDOFF.md`** — what changed, files touched, commands run and results, branch, blockers, next steps.

Full contract: the [AI workspace standard](https://platform.hybridsolutions.cloud/standards/ai-workspace/).

---

## Key facts

| Fact | Value |
|---|---|
| ADO org | <https://dev.azure.com/hybridcloudsolutions> |
| ADO project | N/A - see registry.yaml `ado_project` or ask the HCS Governance MCP `get_repo` for this repo's work-item tracking project |
| Area path | N/A - see registry.yaml or ask the HCS Governance MCP |
| Key Vault | kv-hcs-vault-01 |
| Work item format | `AB#<id>` in commits and PRs |
