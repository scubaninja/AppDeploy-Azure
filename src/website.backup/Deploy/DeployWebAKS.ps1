Param(
    [parameter(Mandatory = $false)][string]$name = "my-tt-web",
    [parameter(Mandatory = $false)][string]$aksName,
    [parameter(Mandatory = $false)][string]$resourceGroup,
    [parameter(Mandatory = $false)][string]$acrName,
    [parameter(Mandatory = $false)][string]$tag = "latest",
    [parameter(Mandatory = $false)][string]$valueSFile = "gvalues.yaml",
    [parameter(Mandatory = $false)][string]$b2cValuesFile = "values.b2c.yaml",
    [parameter(Mandatory = $false)][string]$afHost = "http://your-product-visits-af-here",
    [parameter(Mandatory = $false)][string][ValidateSet('prod', 'staging', 'none', 'custom', IgnoreCase = $false)]$tlsEnv = "none",
    [parameter(Mandatory = $false)][string]$tlsHost = "",
    [parameter(Mandatory = $false)][string]$tlsSecretName = "",
    [parameter(Mandatory = $false)][string]$appInsightsName = "",    
    [parameter(Mandatory = $false)][string]$build = $false,
    [parameter(Mandatory = $false)][string]$subscription = "",
    [parameter(Mandatory = $false)][string]$acsConnectionString = "",
    [parameter(Mandatory = $false)][string]$acsResource = "",
    [parameter(Mandatory = $false)][string]$acsEmail = "",
    [parameter(Mandatory = $false)][string]$logicAppUrl = ""
)

function validate {
    $valid = $true


    if ([string]::IsNullOrEmpty($aksName)) {
        Write-Host "No AKS name. Use -aksName to specify name" -ForegroundColor Red
        $valid = $false
    }
    if ([string]::IsNullOrEmpty($resourceGroup)) {
        Write-Host "No resource group. Use -resourceGroup to specify resource group." -ForegroundColor Red
        $valid = $false
    }

    if ([string]::IsNullOrEmpty($aksHost) -and $tlsEnv -ne "custom") {
        Write-Host "AKS host of HttpRouting can't be found. Are you using right AKS ($aksName) and RG ($resourceGroup)?" -ForegroundColor Red
        $valid = $false
    }     
    if ([string]::IsNullOrEmpty($acrLogin)) {
        Write-Host "ACR login server can't be found. Are you using right ACR ($acrName) and RG ($resourceGroup)?" -ForegroundColor Red
        $valid = $false
    }
    if ($tlsEnv -eq "custom" -and [string]::IsNullOrEmpty($tlsHost)) {
        Write-Host "If tlsEnv is custom must use -tlsHost to set the hostname of AKS (inferred name of Http Application Routing won't be used)"
        $valid = $false
    }
    if ($valid -eq $false) {
        exit 1
    }
}

function buildPushImageDocker() {
    Push-Location $($MyInvocation.InvocationName | Split-Path)
    $sourceFolder = $(./Join-Path-Recursively.ps1 -pathParts .., Source)  

    Write-Host "Getting info from ACR $resourceGroup/$acrName" -ForegroundColor Yellow    
    $acrCredentials = $(az acr credential show -g $resourceGroup -n $acrName -o json | ConvertFrom-Json)
    $acrPwd = $acrCredentials.passwords[0].value
    $acrUser = $acrCredentials.username
    $dockerComposeFile = "docker-compose.yml"

    Write-Host "Using docker compose to build & tag images." -ForegroundColor Yellow
    Write-Host "Images will be named as $acrLogin/imageName:$tag" -ForegroundColor Yellow
    Push-Location $sourceFolder
    $env:TAG = $tag
    $env:REGISTRY = $acrLogin 
    docker-compose -f $dockerComposeFile build   

    Write-Host "Pushing images to $acrLogin" -ForegroundColor Yellow
    docker login -p $acrPwd -u $acrUser $acrLogin
    docker-compose -f $dockerComposeFile push
    Pop-Location
}

function createHelmCommand([string]$command, $chart) {
    $tlsSecretNameToUse = ""
    if ($tlsEnv -eq "staging") {
        $tlsSecretNameToUse = "tt-letsencrypt-staging"
    }
    if ($tlsEnv -eq "prod") {
        $tlsSecretNameToUse = "tt-letsencrypt-prod"
    }
    if ($tlsEnv -eq "custom") {
        $tlsSecretNameToUse = $tlsSecretName
    }

    $newcmd = $command

    if (-not [string]::IsNullOrEmpty($tlsSecretNameToUse)) {
        $newcmd = "$newcmd --set ingress.protocol=https --set ingress.tls[0].secretName=$tlsSecretNameToUse --set ingress.tls[0].hosts={$aksHost}"
    }
    else {
        $newcmd = "$newcmd --set ingress.protocol=http"
    }

    $newcmd = "$newcmd $chart"
    return $newcmd;
}


Write-Host "--------------------------------------------------------" -ForegroundColor Yellow
Write-Host " Deploying images on cluster $aksName"  -ForegroundColor Yellow
Write-Host " "  -ForegroundColor Yellow
Write-Host " Additional parameters are:"  -ForegroundColor Yellow
Write-Host " Release Name: $name"  -ForegroundColor Yellow
Write-Host " AKS to use: $aksName in RG $resourceGroup and ACR $acrName"  -ForegroundColor Yellow
Write-Host " Images tag: $tag"  -ForegroundColor Red
Write-Host " TLS/SSL environment to enable: $tlsEnv"  -ForegroundColor Red
Write-Host " --------------------------------------------------------" 

if ($build -and ([string]::IsNullOrEmpty($acrName))) {
    $acrName = $(az acr list --resource-group $resourceGroup --subscription $subscription -o json | ConvertFrom-Json).name    
}

$acrLogin = $(az acr show -n $acrName -g $resourceGroup | ConvertFrom-Json).loginServer

if ($tlsEnv -ne "custom") {
    $aksHost = $(az aks show -n $aksName -g $resourceGroup | ConvertFrom-Json).addonProfiles.httpApplicationRouting.config.HTTPApplicationRoutingZoneName

    Write-Host "acr login server is $acrLogin" -ForegroundColor Yellow
    Write-Host "aksHost is $aksHost" -ForegroundColor Yellow 
}
else {
    $aksHost = $tlsHost
}

if ($build) {    
    buildPushImageDocker
}

validate

$appinsightsId = ""

## Getting App Insights instrumentation key, if required
if (-not [string]::IsNullOrEmpty($appInsightsName)) {
    $appinsightsConfig = $(az monitor app-insights component show --app $appInsightsName -g $resourceGroup -o json | ConvertFrom-Json)

    if ($appinsightsConfig) {
        $appinsightsId = $appinsightsConfig.instrumentationKey
        Write-Host "App Insights Instrumentation Key: $($appinsightsId)" -ForegroundColor Yellow    
    }
}

Push-Location helm

Write-Host "Deploying web chart" -ForegroundColor Yellow
$command = createHelmCommand "helm upgrade --install $name -f $valuesFile -f $b2cValuesFile --set inf.appinsights.id=$appinsightsId --set az.productvisitsurl=$afHost --set ingress.hosts='{$aksHost}' --set image.repository=$acrLogin/web --set image.tag=$tag --set acsResource=$acsResource --set acsConnectionString=$acsConnectionString --email=$email --set logicAppUrl=$logicAppUrl" "web" 
Invoke-Expression "$command"

Pop-Location

Write-Host "Tailwind traders web deployed on AKS" -ForegroundColor Yellow