Param (
    [Parameter(Mandatory)]
    [ValidateSet("provision")]
    [string]$command,

    [Parameter(Mandatory)]
    [string]$info_json,

    [Parameter(Mandatory, ValueFromPipeline)]
    [string]$stdin
)

function new_temporary_directory {
    $parent = [System.IO.Path]::GetTempPath()
    [string] $guid = [System.Guid]::NewGuid()
    New-Item -ItemType Directory -Path (Join-Path $parent $guid)
}

function winget_provision_package() {
    Param (
        [Parameter(Mandatory)]
        [string]$package
    )

    $result = @{
        status = "success"
        changed = $false
        description = "install package ${package}"
        output = ""
    }

    # check if package installed
    winget list --exact $package | Out-Null
    if (!$?) {
        # install
        $result.output = (winget install --exact --silent $package) -join "`n"
        if (!$?) {
            $result.status = "failed"
            return $result
        }
        $result.changed = $true
    }
    else {
        # check if update required
        $output = (winget upgrade) -join "`n"
        # TODO: unsure if we'll consistently have spaces on both sides, but we want a complete match so... hopefully
        if ($output -like "* ${package} *") {
            # update
            $result.description = "update package ${package}"
            $result.output = (winget upgrade --exact --silent $package) -join "`n"
            if (!$?) {
                $result.status = "failed"
                return $result
            }
            $result.changed = $true
        }
    }

    return $result
}

function winget_install() {
    # import Appx
    if ($PSVersionTable.PSVersion.Major -eq '5') {
        Import-Module Appx
    }
    else {
        Import-Module Appx -UseWindowsPowerShell
        # TODO: -SkipEditionCheck? doesn't work... but without it I get:
        # WARNING: Module Appx is loaded in Windows PowerShell using
        # WinPSCompatSession remoting session; please note that all input and output
        # of commands from this module will be deserialized objects. If you want to
        # load this module into PowerShell please use
        # 'Import-Module -SkipEditionCheck' syntax.
    }

    # find latest release
    $release_url = 'https://api.github.com/repos/microsoft/winget-cli/releases/latest'
    $release = Invoke-RestMethod -Uri $release_url
    $msix = $release.assets | Where {
        $_.name.Equals('Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle')
    } | Select -First 1
    $license = $release.assets | Where {
        $_.name.EndsWith('_License1.xml')
    } | Select -First 1

    # create temp directory
    $temp_dir = new_temporary_directory
    Register-EngineEvent PowerShell.Exiting -Action {
        Remove-Item $temp_dir
    }

    # download deps and winget
    # TODO: handle other architectures?
    # https://learn.microsoft.com/en-us/troubleshoot/developer/visualstudio/cpp/libraries/c-runtime-packages-desktop-bridge#how-to-install-and-update-desktop-framework-packages
    $vc_libs_appx = $temp_dir.ToString() + `
        [IO.Path]::DirectorySeparatorChar + `
        'Microsoft.VCLibs.Desktop.appx'
    Invoke-WebRequest `
        -Uri 'https://aka.ms/Microsoft.VCLibs.x64.14.00.Desktop.appx' `
        -OutFile $vc_libs_appx

    $ui_xaml_appx = $temp_dir.ToString() + `
        [IO.Path]::DirectorySeparatorChar + `
        'Microsoft.UI.Xaml.2.7.x64.appx'
    Invoke-WebRequest `
        -Uri 'https://github.com/microsoft/microsoft-ui-xaml/releases/download/v2.7.3/Microsoft.UI.Xaml.2.7.x64.appx' `
        -OutFile $ui_xaml_appx

    $winget_msixbundle = $temp_dir.ToString() + `
        [IO.Path]::DirectorySeparatorChar + `
        'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
    Invoke-WebRequest `
        -Uri $msix.browser_download_url `
        -OutFile $winget_msixbundle

    $license_xml = $temp_dir.ToString() + `
        [IO.Path]::DirectorySeparatorChar + `
        'License1.xml'
    Invoke-WebRequest `
        -Uri $license.browser_download_url `
        -OutFile $license_xml

    # install
    Add-AppxPackage $vc_libs_appx
    Add-AppxPackage $ui_xaml_appx
    Add-AppxPackage $winget_msixbundle
    Add-AppxProvisionedPackage `
        -Online `
        -PackagePath $winget_msixbundle `
        -LicensePath $license_xml

    # test command
    winget -v

}

function winget_provision_winget_cli() {
    $result = @{
        status = "success"
        changed = $false
        description = "installed winget"
        output = ""
    }

    # ensure winget cli exists
    if (!(Get-Command "winget" -ErrorAction "SilentlyContinue")) {
        $result.output = (winget_install) -join "`n"
        if (!$?) {
            $result.status = "failed"
            return $result
        }
        $result.changed = $true
    }

    # TODO: update winget itself

    return $result
}

function winget_provision() {
    $states = ConvertFrom-Json $stdin

    # install winget
    winget_provision_winget_cli | ConvertTo-Json -Compress

    # provision packages
    foreach ($state in $states) {
        winget_provision_package $state.state | ConvertTo-Json -Compress
    }
}

# disable web request progress
$ProgressPreference = 'SilentlyContinue'

switch ($command) {
    "provision" {
        winget_provision
    }
    default {
        Write-Output "winget: unrecognized subcommand: ${command}"
        exit 1
    }
}
