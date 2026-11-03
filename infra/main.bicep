// Entry point for one environment. Deploy once per environment into that environment's
// own resource group (rg-app-dev, rg-app-qa, rg-app-staging, rg-app-prod), using the matching
// file in ./params.

targetScope = 'resourceGroup'

@description('Environment being deployed.')
@allowed([
  'dev'
  'qa'
  'staging'
  'prod'
])
param environmentName string

@description('Short workload name used in resource names (lowercase letters and digits).')
@minLength(2)
@maxLength(10)
param appName string

@description('Azure region. Defaults to the resource group region.')
param location string = resourceGroup().location

@description('App Service Plan SKU. Use S1 or higher wherever a staging slot is enabled.')
param appServicePlanSku string

@description('App Service Plan instance count.')
@minValue(1)
param appServicePlanCapacity int = 1

@description('Runtime stack for the web app, e.g. DOTNETCORE|8.0, NODE|20-lts, PYTHON|3.12.')
param linuxFxVersion string

@description('Health check path the app serves.')
param healthCheckPath string = '/health'

@description('Create a "staging" deployment slot for deploy-then-swap.')
param enableStagingSlot bool

@description('Enable Key Vault purge protection. Irreversible once on.')
param enableKeyVaultPurgeProtection bool = false

@description('Log Analytics retention in days.')
param logRetentionInDays int = 30

@description('Tags applied to every resource, in addition to the standard ones.')
param tags object = {}

var envAbbreviation = {
  dev: 'dev'
  qa: 'qa'
  staging: 'stg'
  prod: 'prd'
}[environmentName]

// Short, stable per-resource-group suffix for globally unique names.
var suffix = take(uniqueString(resourceGroup().id), 5)

var names = {
  workspace: 'log-${appName}-${envAbbreviation}'
  appInsights: 'appi-${appName}-${envAbbreviation}'
  plan: 'asp-${appName}-${envAbbreviation}'
  webApp: 'app-${appName}-${envAbbreviation}-${suffix}'
  keyVault: 'kv-${take(appName, 10)}-${envAbbreviation}-${suffix}'
}

var allTags = union({
  environment: environmentName
  workload: appName
  managedBy: 'bicep'
}, tags)

module monitoring 'modules/appinsights.bicep' = {
  name: 'monitoring'
  params: {
    location: location
    workspaceName: names.workspace
    appInsightsName: names.appInsights
    retentionInDays: logRetentionInDays
    tags: allTags
  }
}

module appService 'modules/appservice.bicep' = {
  name: 'appService'
  params: {
    location: location
    planName: names.plan
    appName: names.webApp
    skuName: appServicePlanSku
    skuCapacity: appServicePlanCapacity
    linuxFxVersion: linuxFxVersion
    healthCheckPath: healthCheckPath
    appInsightsConnectionString: monitoring.outputs.connectionString
    tags: allTags
  }
}

module stagingSlot 'modules/slots.bicep' = if (enableStagingSlot) {
  name: 'stagingSlot'
  params: {
    location: location
    appName: appService.outputs.appName
    slotName: 'staging'
    linuxFxVersion: linuxFxVersion
    healthCheckPath: healthCheckPath
    appInsightsConnectionString: monitoring.outputs.connectionString
    tags: allTags
  }
}

module keyVault 'modules/keyvault.bicep' = {
  name: 'keyVault'
  params: {
    location: location
    vaultName: names.keyVault
    enablePurgeProtection: enableKeyVaultPurgeProtection
    secretReaderPrincipalIds: enableStagingSlot
      ? [appService.outputs.principalId, stagingSlot.outputs.principalId]
      : [appService.outputs.principalId]
    tags: allTags
  }
}

output webAppName string = appService.outputs.appName
output webAppHostName string = appService.outputs.defaultHostName
output stagingSlotHostName string = enableStagingSlot ? stagingSlot.outputs.defaultHostName : ''
output keyVaultName string = keyVault.outputs.vaultName
output keyVaultUri string = keyVault.outputs.vaultUri
