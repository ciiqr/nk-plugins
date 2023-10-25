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
    $output = (choco search --limit-output --exact --local $package) -join "`n"
    if (!($output -match "(?mi)^${package}\|.*")) {
        # install
        $result.output = (choco install --exact -y $package) -join "`n"
        if (!$?) {
            $result.status = "failed"
            return $result
        }
        $result.changed = $true
    }
    else {
        # check if update required
        $output = (choco outdated --limit-output) -join "`n"
        if ($output -match "(?mi)^${package}\|.*") {
            # update
            $result.description = "update package ${package}"
            $result.output = (choco upgrade --limit-output -y $package) -join "`n"
            if (!$?) {
                $result.status = "failed"
                return $result
            }
            $result.changed = $true
        }
    }

    return $result
}

function chocolatey_provision() {
    $states = ConvertFrom-Json $stdin

    # ensure chocolatey cli exists
    if (!(Get-Command "choco" -ErrorAction "SilentlyContinue")) {
        # TODO: install chocolatey?
        @{
            status = "failed"
            changed = $false
            description = "chocolatey"
            output = "command not found: choco"
        } | ConvertTo-Json -Compress

        return
    }

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
