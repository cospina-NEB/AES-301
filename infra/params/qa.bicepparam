using '../main.bicep'

// QA/Test: deploy to slot, then swap. Standard tier is the minimum that supports slots.
param environmentName = 'qa'
param appName = 'aes301'
param appServicePlanSku = 'S1'
param linuxFxVersion = 'DOTNETCORE|8.0' // TODO: set to the real app runtime
param enableStagingSlot = true
param enableKeyVaultPurgeProtection = false
param logRetentionInDays = 30
