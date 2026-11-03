# Azure DevOps Ecosystem: Claude → Git → Pipelines → Environments → Prod

**Stack decisions:** Azure App Service (compute), Bicep (IaC), Claude API integrated into CI/CD.

---

## 1. Repository Layer (Git)

**Branching strategy — trunk-based with short-lived feature branches:**

- `main` — always deployable, protected
- `feature/*` — Claude and devs work here, short-lived
- `release/*` — optional, only if you need release trains vs. continuous deploy

**Branch policies on `main`:**

- Require PR + minimum 1-2 reviewers
- Require build validation (linked CI pipeline) to pass
- Require linked work item (Azure Boards)
- No direct pushes, no force-push
- Path-based build policies if it's a monorepo

**Where Claude fits:** Claude Code (or Claude in your IDE) works on feature branches, opens PRs, writes commit messages, and can respond to PR review comments. Use a PR template that forces: description, testing done, rollback plan — Claude can auto-populate this.

---

## 2. CI Pipeline (build + validate)

Triggered on PR and on merge to `main`. Azure Pipelines YAML, stored in-repo (`azure-pipelines.yml` or split into templates under `/pipelines`).

**Stages:**

1. **Restore/Build** — compile, install deps
2. **Static analysis** — lint, SAST (e.g., CodeQL, Bandit/Semgrep depending on stack), dependency/license scan
3. **Unit tests** — with coverage gate (e.g., fail under 70-80%)
4. **Package/artifact** — produce zip/build artifact for App Service, push to Azure Artifacts feed
5. **IaC validation** — `az deployment group what-if` on every PR touching `/infra`

Use **pipeline templates** (reusable YAML) so every service/repo follows the same shape — one template repo referenced via `resources.repositories`.

---

## 3. Infrastructure as Code — Bicep

Structure:

```bicep
/infra
  /modules
    appservice.bicep
    keyvault.bicep
    appinsights.bicep
    slots.bicep
  main.bicep
  /params
    dev.bicepparam
    qa.bicepparam
    staging.bicepparam
    prod.bicepparam
```

- One resource group per environment (`rg-app-dev`, `rg-app-qa`, `rg-app-staging`, `rg-app-prod`) — cleaner blast radius and RBAC than shared RGs.
- **Prod gets its own App Service Plan tier** (not shared with lower envs) — isolate cost and noisy-neighbor risk.
- Each env's App Service gets a **staging slot** for zero-downtime swap deploys, including Prod itself (deploy to `prod-staging` slot → smoke test → swap).

---

## 4. CD Pipeline — App Service

Multi-stage YAML pipeline using **Azure DevOps Environments** for deployment targets, giving deployment history, approval gates, and resource-level tracking per environment.

| Environment | Compute | Deploy trigger | Approval | Notes |
| --- | --- | --- | --- | --- |
| **Dev** | App Service | Auto on merge to `main` | None | Direct deploy, no slot needed |
| **QA/Test** | App Service + slot | Auto after Dev smoke test | Optional (QA lead) | Deploy to slot → swap |
| **Staging/UAT** | App Service + slot | Manual or on tag | Required (product owner) | Deploy to slot → run integration/UAT suite → swap |
| **Prod** | App Service + slot (own plan) | Manual promotion | Required, 2+ approvers | Deploy to `prod-staging` slot → automated smoke tests → approval → swap → post-swap health check → auto-swap-back on failure |

Use `AzureAppServiceManage@0` with `SwapSlots` action for the swap step, gated by an Azure Monitor availability test or custom health-check script.

---

## 5. Secrets & Config

- Azure Key Vault per environment, referenced via **Variable Groups** linked to Key Vault in each pipeline environment
- Service connections scoped per environment with least-privilege service principals (Dev SP can't touch Prod resources)
- No secrets in YAML or repo, ever — enforce with a pre-commit secret scanner

---

## 6. Claude API in the Pipeline

Variable group (`claude-api`) backed by Key Vault holding the Anthropic API key, scoped only to the pipeline stages that need it (not exposed to app runtime).

**Integration points, roughly in order of ROI:**

### a) PR risk/summary bot (highest value, easiest to build)

- CI stage after the diff is known: script calls Claude API with the PR diff + changed file list
- Prompt: summarize the change, flag risk areas (auth, payments, migrations, infra changes), suggest what reviewers should focus on
- Post result as a PR comment via Azure DevOps REST API

### b) Infra diff explainer

- After `az deployment group what-if`, pipe the output through Claude to turn it into a plain-English summary (e.g., "this will delete the staging slot for App X and resize the App Service Plan") — attach to the PR alongside the raw what-if output

### c) Failed-build triage

- On pipeline failure, a post-failure step sends the failed step's logs to Claude, asks for a likely root cause and fix suggestion, posts it as a pipeline run comment or Teams/Slack message

### d) Pre-Prod approval brief

- Right before the Prod approval gate, auto-generate a one-paragraph release brief (what's changing, what was tested, rollback plan) from commit messages + linked work items, attached to the approval request

**Implementation shape** (Azure Pipelines task, bash/pwsh script):

```yaml
- script: |
    curl https://api.anthropic.com/v1/messages \
      -H "x-api-key: $(ANTHROPIC_API_KEY)" \
      -H "content-type: application/json" \
      -H "anthropic-version: 2023-06-01" \
      -d '{
        "model": "claude-sonnet-4-6",
        "max_tokens": 1000,
        "messages": [{"role": "user", "content": "..."}]
      }' > claude_response.json
  env:
    ANTHROPIC_API_KEY: $(claude-api-key)
```

Then a small script parses the response and posts it via the Azure DevOps REST API:
`POST https://dev.azure.com/{org}/{project}/_apis/git/repositories/{repo}/pullRequests/{prId}/threads`

**Guardrail:** Claude's output here is advisory only — it summarizes and flags, it doesn't gate merges or approve deployments by itself. Human approvers stay the actual gate on Staging/Prod.

---

## 7. Governance / Guardrails

- Azure Policy on subscriptions/resource groups per environment (e.g., enforce tagging, region restrictions, SKU limits in Dev to control cost)
- Required reviewers on the pipeline YAML files themselves (so no one quietly adds a stage that skips approval)
- Audit: Azure DevOps + Azure Activity Log feeding into a central Log Analytics workspace
- No manual portal changes ("ClickOps") once this is live — all infra changes go through PR + pipeline

---

## 8. Observability (post-deploy)

- App Insights / Azure Monitor wired per environment
- Post-deploy smoke test stage hits health endpoints before marking the environment "healthy"
- Auto-rollback trigger (slot swap back, or redeploy last good artifact) if smoke tests fail in Prod

---

## Summary Table

| Env | Compute | Deploy trigger | Approval | Claude touchpoints |
| --- | --- | --- | --- | --- |
| Dev | App Service | Auto on merge | None | PR summary bot |
| QA | App Service + slot | Auto after Dev smoke test | Optional | — |
| Staging | App Service + slot | Manual/tag | Required | Infra diff explainer |
| Prod | App Service + slot (own plan) | Manual promote | Required, 2 approvers | Release brief, failed-build triage |

---

## Next Steps

1. Scaffold repo layout with Bicep modules per environment
2. Write multi-stage `azure-pipelines.yml`
3. Build the Claude-API PR-bot script and wire into CI
4. Set up Azure DevOps Environments with approval gates
5. Configure Key Vault + variable groups per environment
