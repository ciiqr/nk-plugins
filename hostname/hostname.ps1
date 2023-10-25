Param (
    [Parameter(Mandatory)]
    [ValidateSet("provision")]
    [string]$command,

    [Parameter(Mandatory)]
    [string]$info_json,

    [Parameter(Mandatory, ValueFromPipeline)]
    [string]$stdin
)

function hostname_provision_computer_name() {
    Param (
        [Parameter(Mandatory)]
        [string]$hostname
    )

    $result = @{
        status = "success"
        changed = $false
        description = "hostname ${hostname}"
        output = ""
    }

    if ($env:ComputerName -ne $hostname) {
        $result.output = (Rename-Computer -NewName $hostname -Force) -join "`n"
        if (!$?) {
            $result.status = "failed"
            return $result
        }
        $result.changed = $true
    }

    return $result
}

function hostname_provision() {
    $states = ConvertFrom-Json $stdin

    # provision hostname
    foreach ($state in $states) {
        hostname_provision_computer_name $state.state | ConvertTo-Json -Compress
    }
}

switch ($command) {
    "provision" {
        hostname_provision
    }
    default {
        Write-Output "hostname: unrecognized subcommand: ${command}"
        exit 1
    }
}
