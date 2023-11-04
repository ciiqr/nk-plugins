Param (
    [Parameter(Mandatory)]
    [ValidateSet("provision")]
    [string]$command,

    [Parameter(Mandatory)]
    [string]$info_json,

    [Parameter(Mandatory, ValueFromPipeline)]
    [string]$stdin
)

function powercfg_provision_plan() {
    Param (
        [Parameter(Mandatory)]
        [string]$plan
    )

    $result = @{
        status = "success"
        changed = $false
        description = "powercfg plan ${plan}"
        output = ""
    }

    $new_plan = powercfg -l | ForEach-Object {
        if ($_.contains("($plan)")) {
            $_.split()[3]
        }
    }
    $current_plan = $(powercfg -getactivescheme).split()[3]

    if ($current_plan -ne $new_plan) {
        $result.output = (powercfg -setactive $new_plan *>&1) -join "`n"
        if (!$?) {
            $result.status = "failed"
            return $result
        }
        $result.changed = $true
    }

    return $result
}

function powercfg_provision() {
    $states = ConvertFrom-Json $stdin

    foreach ($state in $states) {
        powercfg_provision_plan $state.state.plan | ConvertTo-Json -Compress
    }
}

switch ($command) {
    "provision" {
        powercfg_provision
    }
    default {
        Write-Output "windows-powercfg: unrecognized subcommand: ${command}"
        exit 1
    }
}
