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
    if (!($output -like "${package}|*")) {
        # install
        $result.changed = $true
        $output = (choco install --exact -y $package) -join "`n"
        if (!$?) {
            $result.status = "failed"
            $result.output = $output
            return $result
        }
    }
    else {
        # check if update required
        $output = (choco outdated --limit-output) -join "`n"
        if ($output -match "^${package}\|.*") {
            # update
            $result.changed = $true
            $result.description = "update package ${package}"
            $output = (choco upgrade --limit-output -y $package) -join "`n"
            if (!$?) {
                $result.status = "failed"
                $result.output = $output
                return $result
            }
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
        echo "chocolatey: unrecognized subcommand: ${command}"
        exit 1
    }
}