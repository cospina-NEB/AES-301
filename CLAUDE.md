# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository status

AES-301 ("CHCM Azure Dev Ecosystem") follows [azure-devops-ecosystem-plan.md](azure-devops-ecosystem-plan.md), the design spec for everything here. Its "Next Steps" list tracks progress. Step 1 (the Bicep scaffold in `/infra`) is done. Pipelines, the Claude PR bot, and the application code don't exist yet.

## Commands

These need the Azure CLI (`az`), which includes Bicep. Every environment has its own resource group, and `main.bicep` is resource-group scoped, so create the group before the first deploy.

```sh
az bicep build --file infra/main.bicep                       # compile + lint (rules in bicepconfig.json)
az bicep build-params --file infra/params/dev.bicepparam     # check one param file against main.bicep

az group create -n rg-app-dev -l <region>
az deployment group what-if -g rg-app-dev -f infra/main.bicep -p infra/params/dev.bicepparam
az deployment group create  -g rg-app-dev -f infra/main.bicep -p infra/params/dev.bicepparam
```

## Infra layout

- `infra/main.bicep` deploys one environment, wiring the modules in this order: `appinsights` (Log Analytics + workspace-based App Insights) → `appservice` (Linux plan + web app with a system-assigned identity) → `slots` (optional `staging` slot) → `keyvault`. Key Vault uses RBAC, and its module grants *Key Vault Secrets User* to the managed identities of the app and the slot. That's why it's deployed last.
- Resource names come from `appName` plus an environment abbreviation (`dev`/`qa`/`stg`/`prd`). The web app and Key Vault names, which must be globally unique, also get a 5-character `uniqueString(resourceGroup().id)` suffix. Key Vault names are limited to 24 characters, which is why `appName` is capped at 10.
- `infra/params/*.bicepparam` holds every per-environment difference: SKU, instance count, whether a slot exists, purge protection, and log retention. Dev uses B1 with no slot. QA and Staging use S1 with a slot (S1 is the lowest tier that supports slots). Prod uses P1v3 with 2 instances, a slot, and purge protection. Change these files instead of adding environment conditionals to `main.bicep`.
- `linuxFxVersion` is currently a placeholder (`DOTNETCORE|8.0`) because the app's stack isn't decided yet.
- The PR template is in `.azuredevops/pull_request_template.md`.

## Target architecture (from the plan)

The flow is Claude → Git → Azure Pipelines → Azure DevOps Environments (Dev → QA → Staging → Prod).

- **Stack:** Azure App Service for compute, Bicep for IaC, Azure Pipelines YAML for CI/CD, and the Claude API called from pipeline steps.
- **Pipelines (not built yet):** `azure-pipelines.yml`, or reusable templates under `/pipelines`.
- **Environments:** each environment gets its own resource group (`rg-app-<env>`). Prod gets its own App Service Plan. QA, Staging, and Prod deploy to a staging slot first, then swap with `AzureAppServiceManage@0` `SwapSlots`. Prod adds post-swap health checks and swaps back automatically on failure.
- **CI stages:** restore/build → static analysis (SAST plus dependency scan) → unit tests with a coverage gate → package to Azure Artifacts → `what-if` on PRs that touch `/infra`.
- **Secrets:** one Key Vault per environment, exposed to pipelines through Key Vault–linked Variable Groups. Service principals are scoped to a single environment. Secrets never go in YAML or the repo. The Anthropic key sits in a `claude-api` variable group that only the stages calling Claude can use; the app runtime never gets it.

## Conventions to follow

- Use trunk-based development. `main` is protected and always deployable. Do work on short-lived `feature/*` branches and merge through a PR that has a linked Azure Boards work item and a passing build.
- PR descriptions must cover: description, testing done, and rollback plan.
- Pipeline integrations that call Claude (PR risk summary, explaining infra `what-if` output, triaging failed builds, the pre-Prod release brief) are **advisory only**. They post comments through the Azure DevOps REST API. They must never gate merges or approve deployments.
- Make every infra change through a PR and the pipeline. No portal changes.
- The sample API call in the plan uses `claude-sonnet-4-6`. Use a current model ID (for example `claude-sonnet-5-5`) when implementing.
