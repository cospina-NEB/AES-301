using '../main.bicep'

// Staging/UAT: deploy to slot, run integration/UAT suite, then swap.
param environmentName = 'staging'
param appName = 'aes301'
param appServicePlanSku = 'S1'
param linuxFxVersion = 'DOTNETCORE|8.0' // TODO: set to the real app runtime
param enableStagingSlot = true
param enableKeyVaultPurgeProtection = false
param logRetentionInDays = 30
