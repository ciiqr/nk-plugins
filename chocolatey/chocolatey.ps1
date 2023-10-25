Param (
    [Parameter(Mandatory)]
    [ValidateSet("provision")]
    [string]$command,

    [Parameter(Mandatory)]
    [string]$info_json,

    [Parameter(Mandatory, ValueFromPipeline)]
    [string]$stdin
)

function chocolatey_provision_package() {
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
    $output = (choco search --limit-output --exact --local $package *>&1) -join "`n"
    if (!($output -match "(?mi)^${package}\|.*")) {
        # install
        $result.output = (choco install --exact -y $package *>&1) -join "`n"
        if (!$?) {
            $result.status = "failed"
            return $result
        }
        $result.changed = $true
    }
    else {
        # check if update required
        $output = (choco outdated --limit-output *>&1) -join "`n"
        if ($output -match "(?mi)^${package}\|.*") {
            # update
            $result.description = "update package ${package}"
            $result.output = (choco upgrade --limit-output -y $package *>&1) -join "`n"
            if (!$?) {
                $result.status = "failed"
                return $result
            }
            $result.changed = $true
        }
    }

    return $result
}

function choco_install() {
    Invoke-Expression (
        (New-Object System.Net.WebClient).DownloadString(
            'https://community.chocolatey.org/install.ps1'
        )
    )
}

function chocolatey_provision_choco_cli() {
    $result = @{
        status = "success"
        changed = $false
        description = "installed choco"
        output = ""
    }

    # ensure choco cli exists
    if (!(Get-Command "choco" -ErrorAction "SilentlyContinue")) {
        $result.output = (choco_install *>&1) -join "`n"
        if (!$?) {
            $result.status = "failed"
            return $result
        }
        $result.changed = $true
    }

    # TODO: choco upgrade chocolatey

    return $result
}

function chocolatey_provision() {
    $states = ConvertFrom-Json $stdin

    # install choco
    chocolatey_provision_choco_cli | ConvertTo-Json -Compress

    # provision packages
    foreach ($state in $states) {
        chocolatey_provision_package $state.state | ConvertTo-Json -Compress
    }
}

switch ($command) {
    "provision" {
        chocolatey_provision
    }
    default {
        Write-Output "chocolatey: unrecognized subcommand: ${command}"
        exit 1
    }
}
