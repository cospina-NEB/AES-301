using '../main.bicep'

// Prod: own Premium plan, 2 instances, slot swap with health checks, purge-protected vault.
param environmentName = 'prod'
param appName = 'aes301'
param appServicePlanSku = 'P1v3'
param appServicePlanCapacity = 2
param linuxFxVersion = 'DOTNETCORE|8.0' // TODO: set to the real app runtime
param enableStagingSlot = true
param enableKeyVaultPurgeProtection = true
param logRetentionInDays = 90
