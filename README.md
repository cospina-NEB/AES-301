# AES-301

CHCM Azure Dev Ecosystem: a delivery path that runs Claude → Git → Azure Pipelines → Azure DevOps Environments → Prod. The app runs on Azure App Service, Bicep defines the infrastructure, and pipeline steps call the Claude API for advisory reviews.

The full design is in [azure-devops-ecosystem-plan.md](azure-devops-ecosystem-plan.md).

## Status

| Step | | Status |
| --- | --- | --- |
| 1 | Scaffold repo layout with Bicep modules per environment | Done |
| 2 | Multi-stage `azure-pipelines.yml` | Not started |
| 3 | Claude API PR-bot script wired into CI | Not started |
| 4 | Azure DevOps Environments with approval gates | Not started |
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
bicepconfig.json          # Bicep linter rules
.azuredevops/
  pull_request_template.md
```

## Environments

Each environment has its own resource group and App Service Plan. All the differences between environments live in the `infra/params/` files.

| Env | Resource group | Plan | Staging slot | Deploy trigger | Approval |
| --- | --- | --- | --- | --- | --- |
| Dev | `rg-app-dev` | B1 | No | Auto on merge to `main` | None |
| QA | `rg-app-qa` | S1 | Yes | Auto after Dev smoke test | Optional |
| Staging | `rg-app-staging` | S1 | Yes | Manual or on tag | Product owner |
| Prod | `rg-app-prod` | P1v3 × 2 | Yes | Manual promotion | 2+ approvers |

The deploy triggers and approvals take effect once steps 2 and 4 are built.

## Deploying infrastructure

You need the [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli), which includes Bicep, and permission to create resources in the target subscription.

```sh
# Compile and lint
az bicep build --file infra/main.bicep

# One-time: create the environment's resource group
az group create -n rg-app-dev -l <region>

# Preview, then apply
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
