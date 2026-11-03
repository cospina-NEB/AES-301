using '../main.bicep'

// Dev: auto-deployed on merge to main. Direct deploy, no slot, smallest paid tier.
param environmentName = 'dev'
param appName = 'aes301'
param appServicePlanSku = 'B1'
param linuxFxVersion = 'DOTNETCORE|8.0' // TODO: set to the real app runtime
param enableStagingSlot = false
param enableKeyVaultPurgeProtection = false
param logRetentionInDays = 30
