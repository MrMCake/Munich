<#
.SYNOPSIS
Install all required modules specified in the current modules manifest

.DESCRIPTION
IInstall all required modules specified in the current modules manifest

.PARAMETER feedName
Name of the module feed to search in, e.g. Release-Modules

.PARAMETER feedurl
Optional feedurl to set by pipeline. Use {0} in path to specify the feedname
e.g. "https://apps-custom.pkgs.visualstudio.com/_packaging/{0}/nuget/v2"

.PARAMETER systemAccessToken
Authentication token for the provided module feed

.PARAMETER queueById
Id/Email used to require the module feed

.PARAMETER test
An optional parameter used by tests to only run code that is required for testing

.PARAMETER onBuildPipeline
An optional parameter to indicate whether this code runs on the build-pipeline or not. This results in the pre-build to ignore artifacts it cannot find.

.EXAMPLE
$(Build.SourcesDirectory)\$(module.name)\Pipeline\preBuild.ps1 -systemAccessToken $(system.accesstoken) -queueById $(Build.QueuedById) -Verbose

Invoke the Pre-Build of the current module to install all its required modules specified in its manifest
#>

[Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSAvoidUsingConvertToSecureStringWithPlainText", "", Justification = "Is provided by the pipeline as an encoded string")]
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string] $feedName,
    [Parameter(Mandatory = $true)]
    [string] $feedurl,
    [Parameter(Mandatory = $true)]
    [string] $systemAccessToken,
    [Parameter(Mandatory = $true)]
    [string] $queueById,
    [Parameter(Mandatory = $false)]
    [switch] $onBuildPipeline
)

#region build-functions
<#
.SYNOPSIS
Add a given repository as a source for modules

.DESCRIPTION
Add a given repository as a source for modules

.PARAMETER feedurl
Url to the feed to add

.PARAMETER systemAccessToken
Access token required to access the feed

.PARAMETER queueById
Id/Email of the instance that wants to access the feed

.EXAMPLE
Set-DefinedPSRepository -feedname "Release-Modules" -feedurl $feedurl -systemAccessToken $systemAccessToken -queueById $queueById

Set the feed Release-Modules as a nuget and repo source with the specified credentials
#>
function Set-DefinedPSRepository {

    [CmdletBinding(
        SupportsShouldProcess = $true
    )]
    param (
        [Parameter(Mandatory = $true)]
        [string] $feedname,
        [Parameter(Mandatory = $true)]
        [string] $feedurl,
        [Parameter(Mandatory = $true)]
        [string] $systemAccessToken,
        [Parameter(Mandatory = $true)]
        [string] $queueById
    )

    Write-Verbose "Feed-Url: $feedurl"

    Write-Verbose 'Add nuget source definition'
    $nugetSources = nuget sources
    if (!("$nugetSources" -Match $feedName)) {
        nuget sources add -name $feedname -Source $feedurl -Username $queueById -Password $systemAccessToken
    }
    else {
        Write-Verbose "NuGet source $feedname already registered"
    }
    Write-Verbose 'Check registered repositories'
    $regRepos = (Get-PSRepository).Name
    if ($regRepos -notcontains $feedName) {
        if ($PSCmdlet.ShouldProcess("PSRepository", "Register new")) {
            Write-Verbose 'Registering script folder as Nuget repo'
            Register-PSRepository $feedname -SourceLocation $feedurl -PublishLocation $feedurl -InstallationPolicy Trusted
            Write-Verbose "Repository $feedname registered"
        }
    }
    else {
        Write-Verbose "Repository $feedname already registered"
    }

    Write-Verbose ("Available repositories:")
    Get-PSRepository
}

function Install-DefinedModule {
    <#
.SYNOPSIS
Install the provided module

.DESCRIPTION
Either install the module from the provided feed or default PSGallery.

.PARAMETER credential
The credentials used to authenticate towards the feed

.PARAMETER requiredModule
The required module to install

.EXAMPLE
Install-RequiredModule -credential $credentials -requiredModule $manifest.RequriedModules[0]

Try install a module specified in the requ
#>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [PSCredential] $credential,
        [Parameter(Mandatory = $true)]
        [Hashtable] $definedModule,
        [Parameter(Mandatory = $true)]
        [switch] $onBuildPipeline
    )

    $myargs = @{
        Credential = $credential
        Name       = $definedModule.ModuleName
    }
    if ($definedModule.ModuleVersion) {
        $myargs["MinimumVersion"] = $definedModule.ModuleVersion
    }

    $IsKnownModule = Get-Module -Name $definedModule.ModuleName -ListAvailable
    if ($IsKnownModule -and $IsKnownModule.Version -contains $definedModule.ModuleVersion) {
        Write-Verbose ("Module {0} with Version {1} already installed" -f $definedModule.ModuleName, $definedModule.ModuleVersion)
        continue
    }

    Write-Verbose ("Try to install required module {0}" -f $definedModule.ModuleName)
    try {
        Install-Module @myargs -Force
        Write-Verbose ("Installed module {0}" -f $definedModule.ModuleName)
        $installedModule = Get-Module -Name $definedModule.ModuleName -ListAvailable
        Write-Verbose ("Versions now installed: {0}" -f $installedModule.Version)
    }
    catch {
        if ($onBuildPipeline) {
            Write-Warning ("Module {0} not found. Flag indicates current location is the Build Pipeline. Dependency is forwarded to RequiredModule.psd1" -f $definedModule.ModuleName)
        }
        else {
            throw ("Unable to Install-Module. Error: {0}" -f $_.Exception.Message)
        }
    }
}
#endregion

$oldPreferences = $VerbosePreference
$VerbosePreference = "Continue"

try {
    $moduleBase = Split-Path "$PSScriptRoot" -Parent
    $moduleName = Split-Path $moduleBase -Leaf

    $feedurl = $feedurl -f $feedName
    Set-DefinedPSRepository -feedname $feedName -feedurl $feedurl -systemAccessToken $systemAccessToken -queueById $queueById

    $password = ConvertTo-SecureString $systemAccessToken -AsPlainText -Force
    $credential = New-Object System.Management.Automation.PSCredential ($queueById, $password)

    $manifest = Import-PowerShellDataFile (Join-Path $moduleBase "$moduleName.psd1")
    foreach ($requiredModule in $manifest.RequiredModules) {
        $RequiredInputObject = @{
            cred            = $credential
            definedModule   = $requiredModule
            onBuildPipeline = $onBuildPipeline
        }
        Install-DefinedModule @RequiredInputObject
    }

    $SourceInputObject = @{
        cred            = $credential
        definedModule   = @{ModuleName = $moduleName}
        onBuildPipeline = $onBuildPipeline
    }
    Install-DefinedModule @SourceInputObject
}
finally {
    $VerbosePreference = $oldPreferences
}
