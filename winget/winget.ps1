Param (
    [Parameter(Mandatory)]
    [ValidateSet("provision")]
    [string]$command,

    [Parameter(Mandatory)]
    [string]$info_json,

    [Parameter(Mandatory, ValueFromPipeline)]
    [string]$stdin
)

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
        $result.changed = $true
        $output = (winget install --exact --silent $package) -join "`n"
        if (!$?) {
            $result.status = "failed"
            $result.output = $output
            return $result
        }
    }
    else {
        # check if update required
        $output = (winget upgrade) -join "`n"
        # TODO: unsure if we'll consistently have spaces on both sides, but we want a complete match so... hopefully
        if ($output -like "* ${package} *") {
            # update
            $result.changed = $true
            $result.description = "update package ${package}"
            $output = (winget upgrade --exact --silent $package) -join "`n"
            if (!$?) {
                $result.status = "failed"
                $result.output = $output
                return $result
            }
        }
    }

    return $result
}

function winget_provision() {
    $states = ConvertFrom-Json $stdin

    # ensure winget cli exists
    if (!(Get-Command "winget" -ErrorAction "SilentlyContinue")) {
        # TODO: install winget?
        @{
            status = "failed"
            changed = $false
            description = "winget"
            output = "command not found"
        } | ConvertTo-Json -Compress

        return
    }

    # provision packages
    foreach ($state in $states) {
        winget_provision_package $state.state | ConvertTo-Json -Compress
    }
}

switch ($command) {
    "provision" {
        winget_provision
    }
    default {
        echo "winget: unrecognized subcommand: ${command}"
        exit 1
    }
}
