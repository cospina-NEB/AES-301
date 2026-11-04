# AES-301

CHCM Azure Dev Ecosystem: a delivery path that runs Claude → Git → Azure Pipelines → Azure DevOps Environments → Prod. The app runs on Azure App Service, Bicep defines the infrastructure, and pipeline steps call the Claude API for advisory reviews.

The full design is in [azure-devops-ecosystem-plan.md](azure-devops-ecosystem-plan.md).

## Status

| Step | | Status |
| --- | --- | --- |
| 1 | Scaffold repo layout with Bicep modules per environment | Done |
| 2 | Multi-stage `azure-pipelines.yml` ([AES-304](https://nebulas.atlassian.net/browse/AES-304)) | Written, not yet run |
| 3 | Claude API PR-bot script wired into CI | Not started |
| 4 | Azure DevOps Environments with approval gates ([AES-305](https://nebulas.atlassian.net/browse/AES-305)) | Setup script written, not yet run |
| 5 | Key Vault + variable groups per environment | Not started |

## Repository layout

```text
infra/
  main.bicep              # deploys one environment into its resource group
  modules/
    appinsights.bicep     # Log Analytics workspace + App Insights
    appservice.bicep      # Linux App Service Plan + Web App (managed identity)
    slots.bicep           # "staging" deployment slot for deploy-then-swap
    keyvault.bicep        # RBAC Key Vault; app and slot identities can read secrets
  params/
    dev.bicepparam
    qa.bicepparam
    staging.bicepparam
    prod.bicepparam
azure-pipelines.yml       # pipeline entry point: stage order and triggers
pipelines/
  variables/common.yml    # app name, .NET version, solution path, coverage gate, feed
  templates/
    jobs/                 # CI: build-dotnet, validate-infra
    stages/               # deploy-env (one per environment), swap-slot (Prod)
    steps/                # deploy-infra, smoke-test, swap-and-verify
scripts/
  setup-environments.ps1  # one-time / re-runnable: RGs, pipeline identities, service connections, ADO Environments + checks
bicepconfig.json          # Bicep linter rules
.azuredevops/
  pull_request_template.md
```

## Pipeline

| Trigger | What runs |
| --- | --- |
| PR to `main` | CI: restore, build, `dotnet format`, vulnerable-package scan, Semgrep, unit tests with a 75% line-coverage gate, package. Also Bicep lint, plus what-if for Dev and QA if the PR touches `/infra` |
| Merge to `main` | CI → Dev → QA |
| Tag `v*`, or a manual run with **Promote to Staging** | CI → Dev → QA → Staging → Prod (slot) → Prod (swap) |

Prod has two approval gates. **Prod (slot)** deploys infra and the app to the staging slot, then runs smoke tests. **Prod (swap)** swaps the slot into production, runs a health check, and swaps back automatically if the check fails.

### One-time setup before the first run

1. **Application:** add the .NET 8 solution at `Aes301.sln`, with the web project at `src/Aes301.Web/Aes301.Web.csproj` and at least one test project. The app must serve `GET /health` with HTTP 200. To use different paths, change `pipelines/variables/common.yml`.
2. **Environments:** run [scripts/setup-environments.ps1](scripts/setup-environments.ps1) (see [Setting up environments](#setting-up-environments)). It creates the resource groups, service connections and Azure DevOps Environments, with their approvals and checks.
3. **Pipeline:** create a pipeline from `azure-pipelines.yml` using the GitHub connection. In GitHub branch protection for `main`, make this pipeline's check required. On the first run, authorize the pipeline to use each `sc-aes301-<env>` connection and environment when it asks. The script doesn't grant access to all pipelines.
4. **Optional:** to also push the app zip to Azure Artifacts, set `artifactFeed` in `pipelines/variables/common.yml`.

## Setting up environments

`scripts/setup-environments.ps1` is idempotent: run it again at any time, and it corrects anything that has drifted. Add `-WhatIf` to preview without changing anything.

You need:

- PowerShell 7.2+ and the Azure CLI, signed in with `az login`
- **Owner** or **User Access Administrator** on the subscription
- **Project Administrator** in the Azure DevOps project

```powershell
./scripts/setup-environments.ps1 `
    -Organization https://dev.azure.com/<org> -Project <project> `
    -SubscriptionId <subscription-id> -Location <region> `
    -StagingApprovers '[<project>]\Product Owners' `
    -ProdApprovers '[<project>]\Prod Approvers' `
    -ProdSwapApprovers '[<project>]\Prod Approvers' `
    -WhatIf
```

Approvers can be Azure DevOps groups (`'[Project]\Group'`) or users (email). `-QaApprovers` is optional; QA has no approval if you leave it out. `-Environments dev,qa` limits the run to those environments.

What it sets up for each environment:

| Piece | Name | Notes |
| --- | --- | --- |
| Resource group | `rg-app-<env>` | Tagged `environment`, `workload=aes301` |
| Pipeline identity | `id-aes301-<env>-pipeline` | User-assigned managed identity, with **Contributor** on its resource group only. Also **RBAC Administrator** on that group, limited by a condition to assigning *Key Vault Secrets User*, the one role the Bicep assigns |
| Service connection | `sc-aes301-<env>` | Workload identity federation, so no secret to rotate. Staging and Prod have **branch control** (`main` and `v*` tags), so a feature-branch run can't use them to skip the approvals |
| Azure DevOps Environment | `aes301-<env>` (+ `aes301-prod-swap`) | Approval as in the table below, plus branch control and an exclusive lock on each |

Branch control on the Staging and Prod connections stops PR builds from using them. That's why PR what-if covers only Dev and QA.

> Change approvals and checks by editing and re-running the script, not in the Azure DevOps UI. The next run will overwrite UI changes.

## Environments

Each environment has its own resource group and App Service Plan. All the differences between environments live in the `infra/params/` files.

| Env | Resource group | Plan | Staging slot | Deploy trigger | Approval |
| --- | --- | --- | --- | --- | --- |
| Dev | `rg-app-dev` | B1 | No | Auto on merge to `main` | None |
| QA | `rg-app-qa` | S1 | Yes | Auto after Dev smoke test | Optional (`-QaApprovers`) |
| Staging | `rg-app-staging` | S1 | Yes | Manual or on tag | Product owner (`-StagingApprovers`) |
| Prod (slot) | `rg-app-prod` | P1v3 × 2 | Yes | Manual promotion | 2+ approvers, and the person who requested the run can't approve (`-ProdApprovers`) |
| Prod (swap) | — | — | — | After slot smoke tests pass | `-ProdSwapApprovers` |

The approvals take effect once `scripts/setup-environments.ps1` has been run.

## Deploying infrastructure

You need the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), which includes Bicep, and permission to create resources in the target subscription.

```sh
# Compile and lint
az bicep build --file infra/main.bicep

# Preview (the resource group comes from scripts/setup-environments.ps1), then apply
az deployment group what-if -g rg-app-dev -f infra/main.bicep -p infra/params/dev.bicepparam
az deployment group create  -g rg-app-dev -f infra/main.bicep -p infra/params/dev.bicepparam
```

For another environment, change the resource group and the parameter file. Once the pipelines are in place, infrastructure changes should go through a PR and the pipeline, not manual deploys or portal changes.

> **Note:** the runtime (`linuxFxVersion`) is set to `DOTNETCORE|8.0` as a placeholder until the app's stack is decided. Prod turns on Key Vault purge protection, and that setting can't be undone.

## Contributing

- Work on short-lived `feature/*` branches. `main` is protected and always deployable.
- Every PR needs a linked Azure Boards work item, a passing build and at least one reviewer.
- Fill in all three sections of the PR template: description, testing done and rollback plan.
- Claude's pipeline output (PR summaries, infra diff explanations, build triage, release briefs) is advisory only. Human reviewers and approvers are the actual gates.
- Never put secrets in YAML or the repo. Store them in the environment's Key Vault.
