<#
.SYNOPSIS
    Copy a Dashboard from one Tenant to another

.DESCRIPTION
    This script simply copies a dashboard from one tenant to another with no changes (name changes is optional)

    There is no remediation or process to resolve dashboards that Dynatrace Managed will not accept as-is.

    Possible future features: 
        - Selection of source and destination tenant and dashboard from provided clusters
        - General export of Dashboard json to file

    Changelog: 
        v2.1
            Updated confirm-requireTokenPerms to allow check of source environment
            Removes ID and owner for dashboard
            Added first iteration of Dashboard validation using built-in API
            Updated by Adrian Chen
        v2.0
            Updated name and brought across the default scaffold
            some shuffling of the input args (enough to break compatibility and make this v2)
        v1.0
            Dashboard movement works as expected with user interface

.NOTES
    Version: v2.1 - 20201110
    Author: michael.ball
    Requirements: Powershell 5+

.EXAMPLE
    (out of date)
    ./copy-dashboard.ps1 -dtenv "https://server.example1.com/e/e2a187ff-ba0f-4078-e2b8-126e2b8ba187" -token "adf1231414" -sourceEnvironment "https://server.example.com/e/f9degggf-1115-468a-a997-f9degggfc64a" -sourceToken "asdfa23123jlkf" -sourceDashboardID "123123-123jlkj-123-3-213"

    Moves a dashboard between 2 different environments

.EXAMPLE
    ./copy-dashboard.ps1 -dtenv "https://server.example.com/e/f92341bf-1435-468a-a997-ecd4f9degggf" -token "asdfa23123jlkf" -sourceDashboardID "123123-123jlkj-123-3-213" 

    When no source Environment is set the source is assumed to be the same env as the destination
#>

PARAM (
    # The cluster or tenant the Dasboard will be placed in
    [Parameter()][ValidateNotNullOrEmpty()] $dtenv = $env:dtenv,
    # Token for the destination tenant w/ DataExport and WriteConfig perms
    [Alias('dttoken')][ValidateNotNullOrEmpty()][string] $token = $env:dttoken,

    <##################################
    # Start of Script-specific params #
    ##################################>

    # A shortcut for specifying a new name for the created report
    [ValidateNotNullOrEmpty()][string]$destinationReportName,
    # The URL of the source Environment
    [ValidateNotNullOrEmpty()][String]$sourceEnvironment,
    # The ID of the source Dashboard - just like if you wanted to open it in browser
    [ValidateNotNullOrEmpty()][String]$sourceDashboardID,
    # A Token with DataExport and ReadConfig access to the source Environment
    [ValidateNotNullOrEmpty()][String]$sourceToken,

    # Force the creation of a new dashboard
    [Switch]$force,

    <#################################
    # Stop of Script-specific params #
    #################################>

    # Prints Help output
    [Alias('h')][switch] $help,
    # use this switch to tell this script to not check token or cluster viability
    [switch] $noCheckCompatibility,
    # use this switch to tell powershell to ignore ssl concerns
    [switch] $noCheckCertificate,

    # DO NOT USE - This is set by Script Author
    [String[]]$script:tokenPermissionRequirements = @('DataExport', 'WriteConfig')
)

# Help flag checks
if ($h -or $help) {
    Get-Help $script:MyInvocation.MyCommand.Path -Detailed
    exit 0
}

# Ensure that dtenv and token are both populated
if (!$script:dtenv) {
    return Write-Error "dtenv was not populated - unable to continue"
}
elseif (!$script:token) {
    return Write-Error "token/dttoken was not populated - unable to continue"
}

# Try to 'fix' a missing https:// in the env
if ($script:dtenv -notlike "https://*" -and $script:dtenv -notlike "http://*") {
    Write-Host -ForegroundColor DarkYellow -Object "WARN: Environment URI was missing 'httpx://' prefix"
    $script:dtenv = "https://$script:dtenv"
    Write-host -ForegroundColor Cyan "New environment URL: $script:dtenv"
}

# Try to 'fix' a trailing '/'
if ($script:dtenv[$script:dtenv.Length - 1] -eq '/') { 
    $script:dtenv = $script:dtenv.Substring(0, $script:dtenv.Length - 1) 
    write-host -ForegroundColor DarkYellow -Object "WARNING: Removed trailing '/' from dtenv input"
}

$baseURL = "$script:dtenv/api/v1"

# Setup Network settings to work from less new setups
if ($nocheckcertificate) {
    # SSL and other compatability settings
    function Disable-SslVerification {
        if (-not ([System.Management.Automation.PSTypeName]"TrustEverything").Type) {
            Add-Type -TypeDefinition  @"
using System.Net.Security;
using System.Security.Cryptography.X509Certificates;
public static class TrustEverything
{
    private static bool ValidationCallback(object sender, X509Certificate certificate, X509Chain chain,
    SslPolicyErrors sslPolicyErrors) { return true; }
    public static void SetCallback() { System.Net.ServicePointManager.ServerCertificateValidationCallback = ValidationCallback; }
    public static void UnsetCallback() { System.Net.ServicePointManager.ServerCertificateValidationCallback = null; } } 
"@
        }
        [TrustEverything]::SetCallback()
    }
    function Enable-SslVerification {
        if (([System.Management.Automation.PSTypeName]"TrustEverything").Type) {
            [TrustEverything]::UnsetCallback()
        }
    }
    Disable-SslVerification   
}
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocoltype]::Tls12 

# Construct the headers for this API request 
$headers = @{
    Authorization  = "Api-Token $script:token";
    Accept         = "application/json; charset=utf-8";
    "Content-Type" = "application/json; charset=utf-8"
}

function confirm-supportedClusterVersion ($minimumVersion = 176, $logmsg = '') {
    # Environment version check - cancel out if too old 
    $uri = "$baseURL/config/clusterversion"
    Write-Host -ForegroundColor cyan -Object "Cluster Version Check$logmsg`: GET $uri"
    $res = Invoke-RestMethod -Method GET -Headers $headers -Uri $uri 
    $envVersion = $res.version -split '\.'
    if ($envVersion -and ([int]$envVersion[0]) -ne 1 -and ([int]$envVersion[1]) -lt $minimumVersion) {
        write-host "Failed Environment version check - Expected: > 1.176 - Got: $($res.version)"
        exit
    }
}

function confirm-requireTokenPerms ($token, $requirePerms, $envUrl = $script:dtenv, $logmsg = '') {
    # Token has required Perms Check - cancel out if it doesn't have what's required
    $uri = "$envUrl/api/v1/tokens/lookup"
    Write-Host -ForegroundColor cyan -Object "Token Permissions Check$logmsg`: POST $uri"
    $res = Invoke-RestMethod -Method POST -Headers $headers -Uri $uri -body "{ `"token`": `"$script:token`"}"
    if (($requirePerms | Where-Object { $_ -notin $res.scopes }).count) {
        write-host "Failed Token Permission check. Token requires: $($requirePerms -join ',')"
        write-host "Token provided only had: $($res.scopes -join ',')"
        exit
    }
}

if (!$noCheckCompatibility) {
    <#
        Determine what type environment we have? This script will only work on tenants 
        
        SaaS tenant = https://*.live.dynatrace.com
        Managed tenant = https://*/e/UUID
        Managed Cluster = https://*
    #>
    $envType = 'cluster'
    if ($script:dtenv -like "*.live.dynatrace.com") {
        $envType = 'env'
    }
    elseif ($script:dtenv -like "http*://*/e/*") {
        $envType = 'env'
    }

    # Script won't work on a cluster
    if ($envType -eq 'cluster') {
        write-error "'$script:dtenv' looks like an invalid URL (and Clusters are not supported by this script)"
        return
    }
    
    confirm-supportedClusterVersion 182 -logmsg ' (Destination Cluster)'
    confirm-requireTokenPerms $script:token $script:tokenPermissionRequirements -logmsg ' (Token for Destination Cluster)'
}

<#########################
# Stop of scaffold block #
#########################>

# If no source Environment and no sourceFile then this is an intra Environment move/copy
if (!$script:sourceEnvironment -and !$script:sourceFile) {
    $script:sourceEnvironment = $script:dtenv
    $script:sourceToken = $script:token
}

# If we're connecting to another dt tenant, confirm we've got the required creds
if (!$script:sourceFile) {
    <#
        Determine what type environment we have? This script will only work on tenants 
        
        SaaS tenant = https://*.live.dynatrace.com
        Managed tenant = https://*/e/UUID
        Managed Cluster = https://*
    #>
    $envType = 'cluster'
    if ($script:sourceEnvironment -like "*.live.dynatrace.com") {
        $envType = 'env'
    }
    elseif ($script:sourceEnvironment -like "http*://*/e/*") {
        $envType = 'env'
    }

    # Script won't work on a cluster
    if ($envType -eq 'cluster') {
        write-error "'$script:sourceEnvironment' looks like an invalid URL (and Clusters are not supported by this script)"
        return
    }
    
    confirm-supportedClusterVersion 182 -logmsg ' (Source Cluster)'
    confirm-requireTokenPerms $script:sourceToken "DataExport", "ReadConfig" -envUrl $script:sourceEnvironment -logmsg ' (Token for Source Cluster)'
}

function import-DashboardJSON ($environment, $token, [String]$dashboardJSON) {
    $headers = @{
        Authorization  = "Api-Token $Token"
        "Content-Type" = "application/json"
    }
    $url = "$environment/api/config/v1/dashboards"
    $dashboardJSON = $dashboardJSON -replace '%%ENV%%', $environment
    $res = @()
    try {
        $response = Invoke-WebRequest -Method POST -Headers $headers -Uri $url -Body $dashboardJSON -UseBasicParsing -ErrorAction Stop
        $res = $response.content | ConvertFrom-Json
        Write-host "Dashboard created successfully. Name: " -nonewline 
        write-host $res.name -NoNewline -ForegroundColor Gray
        write-host " - ID: " -NoNewline
        write-host $res.id -ForegroundColor Gray
        Write-host "Access URL: " -NoNewline -ForegroundColor Gray
        write-host "$environment/#dashboard;id=$($res.id)" -ForegroundColor cyan
        return $res.id
    }
    catch [System.Net.WebException] {
        $respStream = $_.Exception.Response.getResponseStream()
        $reader = New-Object System.IO.StreamReader($respStream)
        $reader.baseStream.Position = 0
        $res = $reader.ReadToEnd() | ConvertFrom-Json

        write-host "Error attempting to import: $($res.error.code)"
        write-host "Message: $($res.error.message)" -ForegroundColor Red

        Write-error "Import failed - No changes made"
    }
}

function export-Dashboard ($environment, $token, $dashboardID) {
    $headers = @{
        Authorization  = "Api-Token $Token"
        "Content-Type" = "application/json"
    }
    $url = "$environment/api/config/v1/dashboards/$dashboardID"

    write-host -ForegroundColor cyan "Fetch Dashboard JSON: GET $url"
    $response = Invoke-RestMethod -Method GET -Headers $headers -Uri $url

    return $response
}

## First iteration of addition validate dashboard
function validate-DashboardJSON ($environment, $token, [String]$dashboardJSON) {
    $headers = @{
        Authorization  = "Api-Token $Token"
        "Content-Type" = "application/json"
    }
    $url = "$environment/api/config/v1/dashboards/validator"
    try {
        $response = Invoke-WebRequest -Method POST -Headers $headers -Uri $url -Body $dashboardJSON -UseBasicParsing -ErrorAction Stop
        return $response.statusCode
    }
    catch [System.Net.WebException] {
        $errorResponse = $_ | ConvertFrom-Json
        ## MVP for Error output
        write-host "Error attempting to import: $($errorResponse.error.code)"
        write-host "Message: $($_)" -ForegroundColor Red
        exit
    }
}

# collect the source dashboard's structure
$source = export-Dashboard $sourceEnvironment $sourceToken $sourceDashboardID

# destinationReportName isn't required - populate it from the source dashboard if it's missing
if ($script:destinationReportName) {
    $source.dashboardMetadata.name = $script:destinationReportName
}

# Removal of ID and Owner is necessary to ensure 
$source.PSObject.properties.remove('id')
$source.dashboardMetadata.PSObject.properties.remove('owner')

# Convert the exported PSObject back to JSON
$json = $source | ConvertTo-Json -Depth 20 -Compress

write-host "Dashboard source is $($json | Measure-Object -Character | Select-Object -ExpandProperty characters) bytes"

$validation = validate-DashboardJSON $script:dtenv $script:token $json

# upload the new dashboard
$newDashID = import-DashboardJSON $script:dtenv $script:token $json
