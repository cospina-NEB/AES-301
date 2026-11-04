#Requires -Version 7.2
<#
.SYNOPSIS
    Creates (or brings back in line) everything azure-pipelines.yml needs before its first run.

.DESCRIPTION
    Per environment (dev, qa, staging, prod):
      - Resource group          rg-app-<env>
      - Pipeline identity       id-aes301-<env>-pipeline (user-assigned managed identity, in that RG)
      - Role assignments        Contributor + RBAC Administrator on the RG only; the RBAC Administrator
                                assignment is conditioned so it can only assign/delete Key Vault Secrets User
      - Service connection      sc-aes301-<env> (ARM, workload identity federation, no secret)
      - Federated credential    on the identity, trusting that service connection
      - ADO Environment         aes301-<env> with approval / branch control / exclusive lock checks
    Plus the aes301-prod-swap Environment, and branch control on the staging and prod service connections
    so a feature-branch pipeline can't use them outside a gated deployment job.

    Idempotent: every resource is read first, created if missing, and updated if it has drifted.
    Use -WhatIf to preview. Requires an `az login` session with:
      - Owner or User Access Administrator on the subscription (resource groups + role assignments)
      - Project Administrator in the Azure DevOps project (service connections, environments, checks)

.EXAMPLE
    ./scripts/setup-environments.ps1 -Organization https://dev.azure.com/nebulas -Project CHCM `
        -SubscriptionId 00000000-0000-0000-0000-000000000000 -Location eastus `
        -StagingApprovers '[CHCM]\Product Owners' `
        -ProdApprovers '[CHCM]\Prod Approvers' `
        -ProdSwapApprovers '[CHCM]\Prod Approvers' -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    # Azure DevOps organization URL, e.g. https://dev.azure.com/nebulas
    [Parameter(Mandatory)][string]$Organization,

    [Parameter(Mandatory)][string]$Project,

    [Parameter(Mandatory)][string]$SubscriptionId,

    # Region for the resource groups and pipeline identities.
    [Parameter(Mandatory)][string]$Location,

    [ValidateSet('dev', 'qa', 'staging', 'prod')]
    [string[]]$Environments = @('dev', 'qa', 'staging', 'prod'),

    # Azure DevOps users (email) or groups ('[Project]\Group'). QA gets no approval when omitted.
    [string[]]$QaApprovers = @(),
    [string[]]$StagingApprovers = @(),
    [string[]]$ProdApprovers = @(),
    [string[]]$ProdSwapApprovers = @(),

    [ValidateRange(1, 10)][int]$ProdMinApprovers = 2,

    [ValidateRange(1, 43200)][int]$ApprovalTimeoutMinutes = 4320
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 1.0   # 1.0: REST payloads omit optional properties
$script:Cmdlet = $PSCmdlet

# ---------------------------------------------------------------------------------------------------------------
# Constants (naming conventions shared with azure-pipelines.yml and infra/)
# ---------------------------------------------------------------------------------------------------------------
$AppName          = 'aes301'
$AllowedRefs      = 'refs/heads/main,refs/tags/v*'
$AdoResourceId    = '499b84ac-1321-427f-aa17-267ca6975798'   # Azure DevOps (for az access tokens)
$ChecksApi        = 'api-version=7.1-preview.1'

$Roles = @{
    Contributor          = 'b24988ac-6180-42a0-ab88-20f7382dd24c'
    RbacAdministrator    = 'f58310d9-a9f6-439a-9e8d-f62e7b41a168'
    KeyVaultSecretsUser  = '4633458b-17de-408a-b874-0445c86b69e6'   # the only role infra/modules/keyvault.bicep assigns
}

# Check type IDs. Not in the public docs: confirm by reading back a check created in the UI
# (GET .../pipelines/checks/configurations?resourceType=environment&resourceId=<id>&$expand=settings).
$CheckTypes = @{
    Approval      = @{ id = '8C6F20A7-A545-4486-9777-F762FAFE0D4D'; name = 'Approval' }
    TaskCheck     = @{ id = 'fe1de3ee-a436-41b4-bb20-f6eb4cb879a7'; name = 'Task Check' }
    ExclusiveLock = @{ id = '2EF31AD6-BAA0-403A-8B45-2CBC9B4E5563'; name = 'ExclusiveLock' }
}
$BranchControlTask = @{ id = '86b05a0c-73e6-4f7d-b3cf-e38f3b39a75b'; name = 'evaluatebranchProtection'; version = '0.0.1' }

# Lets the RBAC Administrator assignment write/delete role assignments only for Key Vault Secrets User.
$kv = $Roles.KeyVaultSecretsUser
$RbacCondition = "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/write'})) OR " +
                 "(@Request[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$kv})) AND " +
                 "((!(ActionMatches{'Microsoft.Authorization/roleAssignments/delete'})) OR " +
                 "(@Resource[Microsoft.Authorization/roleAssignments:RoleDefinitionId] ForAnyOfAnyValues:GuidEquals {$kv}))"

# ---------------------------------------------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------------------------------------------
$script:Results = [System.Collections.Generic.List[object]]::new()

function Write-Result([string]$Kind, [string]$Name, [string]$Status) {
    $script:Results.Add([pscustomobject]@{ Kind = $Kind; Name = $Name; Status = $Status })
    Write-Host ("  {0,-22} {1,-40} {2}" -f $Kind, $Name, $Status)
}

# Routes every change through the script's own -WhatIf/-Confirm handling.
function Confirm-Change {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSShouldProcess', '', Justification = 'Delegates to the script-level ShouldProcess.')]
    param([string]$Target, [string]$Action)
    return $script:Cmdlet.ShouldProcess($Target, $Action)
}

# Runs az and returns parsed JSON. With -AllowFailure, returns $null instead of throwing (used for "show" lookups).
function Invoke-Az {
    param([Parameter(Mandatory)][string[]]$Arguments, [switch]$AllowFailure)
    $output = & az @Arguments --only-show-errors --output json 2>&1
    if ($LASTEXITCODE -ne 0) {
        if ($AllowFailure) { return $null }
        throw "az $($Arguments -join ' ') failed:`n$($output -join "`n")"
    }
    $text = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    return $text | ConvertFrom-Json -Depth 50
}

function Invoke-Ado {
    param([string]$Method = 'GET', [Parameter(Mandatory)][string]$Uri, $Body)
    $request = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = @{ Authorization = "Bearer $script:AdoToken" }
        ContentType = 'application/json'
    }
    if ($null -ne $Body) { $request.Body = $Body | ConvertTo-Json -Depth 50 }
    return Invoke-RestMethod @request
}

function Resolve-AdoIdentity([string]$Name) {
    $uri = "$script:VsspsBase/_apis/identities?searchFilter=General&filterValue=$([uri]::EscapeDataString($Name))&queryMembership=None&api-version=7.1"
    $found = @((Invoke-Ado -Uri $uri).value)
    if ($found.Count -gt 1) {
        $found = @($found | Where-Object { $_.providerDisplayName -eq $Name -or $_.properties.Account.'$value' -eq $Name })
    }
    if ($found.Count -ne 1) {
        throw "Approver '$Name' matched $($found.Count) Azure DevOps identities; use the exact '[Project]\Group' name or the user's email."
    }
    return [pscustomobject]@{ id = $found[0].id; displayName = $found[0].providerDisplayName }
}

# ---------------------------------------------------------------------------------------------------------------
# Azure resources
# ---------------------------------------------------------------------------------------------------------------
function Set-ResourceGroup([string]$EnvName) {
    $name = "rg-app-$EnvName"
    $tags = @("environment=$EnvName", "workload=$AppName", 'managedBy=setup-script')
    $rg = Invoke-Az @('group', 'show', '--name', $name) -AllowFailure
    if (-not $rg) {
        if (Confirm-Change $name 'Create resource group') {
            $rg = Invoke-Az (@('group', 'create', '--name', $name, '--location', $Location, '--tags') + $tags)
            Write-Result 'Resource group' $name 'created'
        } else { Write-Result 'Resource group' $name 'would create' }
        return $rg
    }
    $missing = @($tags | Where-Object { $k, $v = $_ -split '=', 2; -not ($rg.tags -and $rg.tags.$k -eq $v) })
    if ($missing) {
        if (Confirm-Change $name "Merge tags $($missing -join ', ')") {
            Invoke-Az (@('tag', 'update', '--resource-id', $rg.id, '--operation', 'Merge', '--tags') + $missing) | Out-Null
            Write-Result 'Resource group' $name 'updated (tags)'
        } else { Write-Result 'Resource group' $name 'would update (tags)' }
    } else { Write-Result 'Resource group' $name 'unchanged' }
    return $rg
}

function Set-PipelineIdentity([string]$EnvName) {
    $rgName = "rg-app-$EnvName"
    $name = "id-$AppName-$EnvName-pipeline"
    $identity = Invoke-Az @('identity', 'show', '--resource-group', $rgName, '--name', $name) -AllowFailure
    if ($identity) { Write-Result 'Managed identity' $name 'unchanged'; return $identity }
    if (Confirm-Change $name 'Create user-assigned managed identity') {
        $identity = Invoke-Az @('identity', 'create', '--resource-group', $rgName, '--name', $name, '--location', $Location,
                                '--tags', "environment=$EnvName", "workload=$AppName", 'managedBy=setup-script')
        Write-Result 'Managed identity' $name 'created'
        return $identity
    }
    Write-Result 'Managed identity' $name 'would create'
    return $null
}

function Set-RoleAssignments([string]$EnvName, $Identity, [string]$Scope) {
    $label = "id-$AppName-$EnvName-pipeline"
    $existing = @(Invoke-Az @('role', 'assignment', 'list', '--assignee', $Identity.principalId, '--scope', $Scope))

    $wanted = @(
        @{ Role = 'Contributor';       Id = $Roles.Contributor;       Condition = $null }
        @{ Role = 'RBAC Administrator'; Id = $Roles.RbacAdministrator; Condition = $RbacCondition }
    )
    foreach ($w in $wanted) {
        $target = "$label → $($w.Role)"
        $match = @($existing | Where-Object { $_.roleDefinitionId -like "*/$($w.Id)" -and $_.scope -eq $Scope })
        $normalize = { param($c) if ($c) { ($c -replace '\s', '').ToLowerInvariant() } else { '' } }
        $good = @($match | Where-Object { (& $normalize $_.condition) -eq (& $normalize $w.Condition) })

        if ($good) { Write-Result 'Role assignment' $target 'unchanged'; continue }

        if (-not (Confirm-Change $target "Assign on $Scope")) {
            Write-Result 'Role assignment' $target ($match ? 'would replace (condition drift)' : 'would create')
            continue
        }
        foreach ($stale in $match) { Invoke-Az @('role', 'assignment', 'delete', '--ids', $stale.id) | Out-Null }

        $azArgs = @('role', 'assignment', 'create', '--role', $w.Id, '--scope', $Scope,
                    '--assignee-object-id', $Identity.principalId, '--assignee-principal-type', 'ServicePrincipal')
        if ($w.Condition) { $azArgs += @('--condition', $w.Condition, '--condition-version', '2.0') }

        # A just-created identity can take a minute to replicate; retry instead of failing.
        for ($attempt = 1; ; $attempt++) {
            try { Invoke-Az $azArgs | Out-Null; break }
            catch { if ($attempt -ge 6) { throw }; Start-Sleep -Seconds 15 }
        }
        Write-Result 'Role assignment' $target ($match ? 'replaced (condition drift)' : 'created')
    }
}

function Set-FederatedCredential([string]$EnvName, $Endpoint) {
    $rgName = "rg-app-$EnvName"
    $identityName = "id-$AppName-$EnvName-pipeline"
    $name = "ado-sc-$AppName-$EnvName"
    $issuer = $Endpoint.authorization.parameters.workloadIdentityFederationIssuer
    $subject = $Endpoint.authorization.parameters.workloadIdentityFederationSubject
    if (-not $issuer -or -not $subject) {
        throw "Service connection sc-$AppName-$EnvName did not return a workload identity federation issuer/subject."
    }
    $common = @('--resource-group', $rgName, '--identity-name', $identityName, '--name', $name)
    $cred = Invoke-Az (@('identity', 'federated-credential', 'show') + $common) -AllowFailure

    if ($cred -and $cred.issuer -eq $issuer -and $cred.subject -eq $subject) {
        Write-Result 'Federated credential' $name 'unchanged'; return
    }
    $verb = $cred ? 'update' : 'create'
    if (Confirm-Change $name "$verb federated credential ($subject)") {
        Invoke-Az (@('identity', 'federated-credential', $verb) + $common +
                   @('--issuer', $issuer, '--subject', $subject, '--audiences', 'api://AzureADTokenExchange')) | Out-Null
        Write-Result 'Federated credential' $name "$($verb)d"
    } else { Write-Result 'Federated credential' $name "would $verb" }
}

# ---------------------------------------------------------------------------------------------------------------
# Azure DevOps resources
# ---------------------------------------------------------------------------------------------------------------
function Set-ServiceConnection([string]$EnvName, $Identity) {
    $name = "sc-$AppName-$EnvName"
    $base = "$script:OrgUrl/$script:ProjectName/_apis/serviceendpoint/endpoints"
    $existing = @((Invoke-Ado -Uri "$base`?endpointNames=$([uri]::EscapeDataString($name))&api-version=7.1").value)

    $desired = @{
        name          = $name
        type          = 'azurerm'
        url           = 'https://management.azure.com/'
        description   = "AES-301 $EnvName deployments. Identity id-$AppName-$EnvName-pipeline, scoped to rg-app-$EnvName. Managed by scripts/setup-environments.ps1."
        authorization = @{
            scheme     = 'WorkloadIdentityFederation'
            parameters = @{ tenantid = $script:TenantId; serviceprincipalid = $Identity.clientId }
        }
        data          = @{
            environment      = 'AzureCloud'
            scopeLevel       = 'Subscription'
            subscriptionId   = $SubscriptionId
            subscriptionName = $script:SubscriptionName
            creationMode     = 'Manual'
            identityType     = 'ManagedIdentity'
        }
        isShared      = $false
        isReady       = $true
        serviceEndpointProjectReferences = @(@{
            projectReference = @{ id = $script:ProjectId; name = $script:ProjectName }
            name             = $name
            description      = "AES-301 $EnvName deployments."
        })
    }

    if (-not $existing) {
        if (Confirm-Change $name 'Create service connection (workload identity federation)') {
            $endpoint = Invoke-Ado -Method POST -Uri "$base`?api-version=7.1" -Body $desired
            Write-Result 'Service connection' $name 'created'
            return $endpoint
        }
        Write-Result 'Service connection' $name 'would create'
        return $null
    }

    $endpoint = $existing[0]
    $drift = $endpoint.authorization.scheme -ne 'WorkloadIdentityFederation' -or
             $endpoint.authorization.parameters.serviceprincipalid -ne $Identity.clientId -or
             $endpoint.authorization.parameters.tenantid -ne $script:TenantId -or
             $endpoint.data.subscriptionId -ne $SubscriptionId
    if (-not $drift) { Write-Result 'Service connection' $name 'unchanged'; return $endpoint }

    if (Confirm-Change $name 'Update service connection (identity/subscription drift)') {
        $desired.id = $endpoint.id
        $endpoint = Invoke-Ado -Method PUT -Uri "$base/$($endpoint.id)?api-version=7.1" -Body $desired
        Write-Result 'Service connection' $name 'updated'
    } else { Write-Result 'Service connection' $name 'would update' }
    return $endpoint
}

function Set-AdoEnvironment([string]$Name, [string]$Description) {
    $base = "$script:OrgUrl/$script:ProjectName/_apis/distributedtask/environments"
    $existing = @((Invoke-Ado -Uri "$base`?name=$([uri]::EscapeDataString($Name))&api-version=7.1").value |
                  Where-Object { $_.name -eq $Name })
    if ($existing) { Write-Result 'ADO environment' $Name 'unchanged'; return $existing[0] }
    if (Confirm-Change $Name 'Create Azure DevOps environment') {
        $environment = Invoke-Ado -Method POST -Uri "$base`?api-version=7.1" -Body @{ name = $Name; description = $Description }
        Write-Result 'ADO environment' $Name 'created'
        return $environment
    }
    Write-Result 'ADO environment' $Name 'would create'
    return $null
}

# Ensures exactly one check of the given kind on a resource. $Settings = $null removes it.
# $IsSame compares an existing check's settings/timeout against the desired ones.
function Set-Check {
    param(
        [Parameter(Mandatory)][hashtable]$Resource,      # @{ type = 'environment'|'endpoint'; id; name }
        [Parameter(Mandatory)][string]$Kind,             # Approval | BranchControl | ExclusiveLock
        $Settings,
        [int]$Timeout,
        [scriptblock]$IsSame
    )
    $type = switch ($Kind) { 'Approval' { $CheckTypes.Approval } 'BranchControl' { $CheckTypes.TaskCheck } 'ExclusiveLock' { $CheckTypes.ExclusiveLock } }
    $base = "$script:OrgUrl/$script:ProjectName/_apis/pipelines/checks/configurations"
    $all = @((Invoke-Ado -Uri "$base`?resourceType=$($Resource.type)&resourceId=$($Resource.id)&`$expand=settings&$ChecksApi").value)
    $existing = @($all | Where-Object {
        $_.type.id -eq $type.id -and ($Kind -ne 'BranchControl' -or $_.settings.definitionRef.id -eq $BranchControlTask.id)
    })
    $label = "$($Resource.name): $Kind"

    if ($null -eq $Settings) {
        foreach ($check in $existing) {
            if (Confirm-Change $label 'Remove check') {
                Invoke-Ado -Method DELETE -Uri "$base/$($check.id)?$ChecksApi" | Out-Null
                Write-Result 'Check' $label 'removed'
            } else { Write-Result 'Check' $label 'would remove' }
        }
        return
    }

    $body = @{
        type     = $type
        settings = $Settings
        resource = $Resource
        timeout  = $Timeout
    }
    if (-not $existing) {
        if (Confirm-Change $label 'Create check') {
            Invoke-Ado -Method POST -Uri "$base`?$ChecksApi" -Body $body | Out-Null
            Write-Result 'Check' $label 'created'
        } else { Write-Result 'Check' $label 'would create' }
        return
    }
    $current = $existing[0]
    if ((-not $IsSame -or (& $IsSame $current)) -and $current.timeout -eq $Timeout) {
        Write-Result 'Check' $label 'unchanged'; return
    }
    if (Confirm-Change $label 'Update check') {
        $body.id = $current.id
        Invoke-Ado -Method PATCH -Uri "$base/$($current.id)?$ChecksApi" -Body $body | Out-Null
        Write-Result 'Check' $label 'updated'
    } else { Write-Result 'Check' $label 'would update' }
}

function Set-ApprovalCheck([hashtable]$Resource, [object[]]$Approvers, [int]$MinApprovers, [bool]$RequesterCannotApprove, [string]$Instructions) {
    if (-not $Approvers) { Set-Check -Resource $Resource -Kind Approval -Settings $null; return }
    $ids = @($Approvers | ForEach-Object { $_.id } | Sort-Object)
    $settings = @{
        approvers                 = @($Approvers | ForEach-Object { @{ id = $_.id; displayName = $_.displayName } })
        minRequiredApprovers      = $MinApprovers
        requesterCannotBeApprover = $RequesterCannotApprove
        executionOrder            = 1   # any order
        instructions              = $Instructions
        blockedApprovers          = @()
    }
    $isSame = {
        param($c)
        $currentIds = @($c.settings.approvers | ForEach-Object { $_.id } | Sort-Object)
        ($currentIds -join ',') -eq ($ids -join ',') -and
        $c.settings.minRequiredApprovers -eq $MinApprovers -and
        [bool]$c.settings.requesterCannotBeApprover -eq $RequesterCannotApprove
    }.GetNewClosure()
    Set-Check -Resource $Resource -Kind Approval -Settings $settings -Timeout $ApprovalTimeoutMinutes -IsSame $isSame
}

function Set-BranchControlCheck([hashtable]$Resource) {
    $settings = @{
        displayName   = 'Branch control'
        definitionRef = $BranchControlTask
        inputs        = @{
            allowedBranches          = $AllowedRefs
            ensureProtectionOfBranch = 'false'   # protection lives in GitHub branch protection, not ADO policies
            allowUnknownStatusBranch = 'false'
        }
        retryInterval = 5
    }
    $isSame = { param($c) $c.settings.inputs.allowedBranches -eq $AllowedRefs }.GetNewClosure()
    Set-Check -Resource $Resource -Kind BranchControl -Settings $settings -Timeout 1440 -IsSame $isSame
}

function Set-ExclusiveLockCheck([hashtable]$Resource) {
    Set-Check -Resource $Resource -Kind ExclusiveLock -Settings @{} -Timeout 43200
}

# ---------------------------------------------------------------------------------------------------------------
# Preconditions (fail before changing anything)
# ---------------------------------------------------------------------------------------------------------------

if ('staging' -in $Environments -and -not $StagingApprovers) { throw '-StagingApprovers is required when deploying staging.' }
if ('prod' -in $Environments -and (-not $ProdApprovers -or -not $ProdSwapApprovers)) {
    throw '-ProdApprovers and -ProdSwapApprovers are required when deploying prod.'
}

$script:OrgUrl = $Organization.TrimEnd('/')
$script:ProjectName = $Project
$script:VsspsBase = switch -Regex ($script:OrgUrl) {
    '^https://dev\.azure\.com/([^/]+)$'         { "https://vssps.dev.azure.com/$($Matches[1])"; break }
    '^https://([^./]+)\.visualstudio\.com$'     { "https://$($Matches[1]).vssps.visualstudio.com"; break }
    default { throw "Unrecognized organization URL '$Organization'. Expected https://dev.azure.com/<org>." }
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) is not installed or not on PATH.' }

Write-Host "Checking Azure and Azure DevOps access..."
$account = Invoke-Az @('account', 'show', '--subscription', $SubscriptionId)
$script:TenantId = $account.tenantId
$script:SubscriptionName = $account.name
Invoke-Az @('account', 'set', '--subscription', $SubscriptionId) | Out-Null

$script:AdoToken = (Invoke-Az @('account', 'get-access-token', '--resource', $AdoResourceId)).accessToken
$script:ProjectId = (Invoke-Ado -Uri "$script:OrgUrl/_apis/projects/$([uri]::EscapeDataString($Project))?api-version=7.1").id

$approvers = @{}
foreach ($pair in @(@('qa', $QaApprovers), @('staging', $StagingApprovers), @('prod', $ProdApprovers), @('prod-swap', $ProdSwapApprovers))) {
    $approvers[$pair[0]] = @($pair[1] | Where-Object { $_ } | ForEach-Object { Resolve-AdoIdentity $_ })
}
if ('prod' -in $Environments -and $ProdMinApprovers -gt 1 -and $approvers['prod'].Count -lt $ProdMinApprovers) {
    Write-Warning ("-ProdMinApprovers is $ProdMinApprovers but only $($approvers['prod'].Count) prod approver identity was given. " +
                   'Make sure the group has at least that many members who can approve.')
}

Write-Host "Subscription: $($script:SubscriptionName) ($SubscriptionId)  Project: $Project"

# ---------------------------------------------------------------------------------------------------------------
# Apply
# ---------------------------------------------------------------------------------------------------------------
$approvalPolicy = @{
    qa      = @{ Min = 1;                 NoSelf = $false; Text = 'Approve deploying this build to QA.' }
    staging = @{ Min = 1;                 NoSelf = $false; Text = 'Product owner: approve deploying this build to Staging/UAT.' }
    prod    = @{ Min = $ProdMinApprovers; NoSelf = $true;  Text = 'Promote to Prod: deploys infra and the app to the prod staging slot, then runs smoke tests. The swap is approved separately (aes301-prod-swap).' }
}

foreach ($EnvName in $Environments) {
    Write-Host "`n[$EnvName]"
    $rg = Set-ResourceGroup $EnvName
    $identity = $rg ? (Set-PipelineIdentity $EnvName) : $null

    if ($identity) {
        Set-RoleAssignments $EnvName $identity $rg.id
        $endpoint = Set-ServiceConnection $EnvName $identity
        if ($endpoint) {
            Set-FederatedCredential $EnvName $endpoint
            if ($EnvName -in 'staging', 'prod') {
                # Without this, any pipeline run (e.g. a feature-branch PR) could use the connection from a plain job
                # and skip the environment approvals entirely.
                Set-BranchControlCheck @{ type = 'endpoint'; id = $endpoint.id; name = $endpoint.name }
            }
        }
    } else {
        Write-Host '  (identity, role assignments, service connection and federated credential follow once the above exist)'
    }

    $adoEnv = Set-AdoEnvironment "$AppName-$EnvName" "AES-301 $EnvName (rg-app-$EnvName). Checks managed by scripts/setup-environments.ps1."
    if ($adoEnv) {
        $resource = @{ type = 'environment'; id = [string]$adoEnv.id; name = $adoEnv.name }
        if ($EnvName -eq 'dev') { Set-Check -Resource $resource -Kind Approval -Settings $null }
        else {
            $p = $approvalPolicy[$EnvName]
            Set-ApprovalCheck $resource $approvers[$EnvName] $p.Min $p.NoSelf $p.Text
        }
        Set-BranchControlCheck $resource
        Set-ExclusiveLockCheck $resource
    }

    if ($EnvName -eq 'prod') {
        Write-Host "`n[prod-swap]"
        $swapEnv = Set-AdoEnvironment "$AppName-prod-swap" 'AES-301 prod slot swap gate. Checks managed by scripts/setup-environments.ps1.'
        if ($swapEnv) {
            $resource = @{ type = 'environment'; id = [string]$swapEnv.id; name = $swapEnv.name }
            Set-ApprovalCheck $resource $approvers['prod-swap'] 1 $false 'Go live: swap the smoke-tested prod staging slot into production.'
            Set-BranchControlCheck $resource
            Set-ExclusiveLockCheck $resource
        }
    }
}

Write-Host "`nSummary"
$script:Results | Group-Object Status | Sort-Object Name | ForEach-Object { Write-Host ("  {0,-32} {1}" -f $_.Name, $_.Count) }
if ($WhatIfPreference) { Write-Host "`n-WhatIf: nothing was changed." }
