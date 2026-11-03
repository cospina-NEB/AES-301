// Deployment slot for zero-downtime deploys: deploy to the slot, smoke test, then swap.

@description('Azure region for the resources.')
param location string

@description('Name of the existing Web App that owns the slot.')
param appName string

@description('Slot name.')
param slotName string = 'staging'

@description('Runtime stack; should match the production slot.')
param linuxFxVersion string

@description('Path App Service polls for instance health.')
param healthCheckPath string = '/health'

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

resource app 'Microsoft.Web/sites@2023-12-01' existing = {
  name: appName
}

resource slot 'Microsoft.Web/sites/slots@2023-12-01' = {
  parent: app
  name: slotName
  location: location
  tags: tags
  kind: 'app,linux'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    serverFarmId: app.properties.serverFarmId
    httpsOnly: true
    clientAffinityEnabled: false
    siteConfig: {
      linuxFxVersion: linuxFxVersion
      alwaysOn: true
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

output slotId string = slot.id
output slotName string = slot.name
output defaultHostName string = slot.properties.defaultHostName
output principalId string = slot.identity.principalId
