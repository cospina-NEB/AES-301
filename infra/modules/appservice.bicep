// App Service Plan (Linux) + Web App for one environment.
// Each environment deploys its own plan, so Prod never shares a plan with lower environments.

@description('Azure region for the resources.')
param location string

@description('App Service Plan name.')
param planName string

@description('Web App name (must be globally unique).')
param appName string

@description('App Service Plan SKU name, e.g. B1, S1, P1v3. Deployment slots require Standard (S1) or higher.')
param skuName string

@description('Number of plan instances.')
@minValue(1)
param skuCapacity int = 1

@description('Runtime stack, e.g. DOTNETCORE|8.0, NODE|20-lts, PYTHON|3.12.')
param linuxFxVersion string

@description('Path App Service polls for instance health. The app must serve it.')
param healthCheckPath string = '/health'

@description('Keep the app loaded when idle. Not supported on Free/Shared tiers.')
param alwaysOn bool = true

@description('Application Insights connection string.')
param appInsightsConnectionString string

@description('Additional app settings as a name/value object.')
param appSettings object = {}

param tags object = {}

var baseAppSettings = {
  APPLICATIONINSIGHTS_CONNECTION_STRING: appInsightsConnectionString
  ApplicationInsightsAgent_EXTENSION_VERSION: '~3'
}

var mergedAppSettings = union(baseAppSettings, appSettings)

resource plan 'Microsoft.Web/serverfarms@2023-12-01' = {
  name: planName
  location: location
  tags: tags
  kind: 'linux'
  sku: {
    name: skuName
    capacity: skuCapacity
  }
  properties: {
    reserved: true // required for Linux plans
  }
}

resource app 'Microsoft.Web/sites@2023-12-01' = {
  name: appName
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: plan.id
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      linuxFxVersion: linuxFxVersion
      alwaysOn: alwaysOn
      healthCheckPath: healthCheckPath
      minTlsVersion: '1.2'
      ftpsState: 'Disabled'
      http20Enabled: true
      appSettings: [for setting in items(mergedAppSettings): {
        name: setting.key
        value: string(setting.value)
      }]
    }
  }
}

output planId string = plan.id
output appId string = app.id
output appName string = app.name
output defaultHostName string = app.properties.defaultHostName
output principalId string = app.identity.principalId
