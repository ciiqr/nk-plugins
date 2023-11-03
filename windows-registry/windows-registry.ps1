Param (
    [Parameter(Mandatory)]
    [ValidateSet("provision")]
    [string]$command,

    [Parameter(Mandatory)]
    [string]$info_json,

    [Parameter(Mandatory, ValueFromPipeline)]
    [string]$stdin
)

function registry_provision_key() {
    Param (
        [Parameter(Mandatory)]
        [string]$key,
        $value
    )

    $result = @{
        status = "success"
        changed = $false
        description = "registry ${key}"
        output = ""
    }

    # get item path and property name
    if ($key -match '^(.+)\\([^\\]+)$') {
        $item_path = $Matches[1];
        $prop_name = $Matches[2]
    } else {
        $result.output = 'key does not match expected registry format'
        $result.status = 'failed'
        return $result
    }

    # TODO: allow creating the key if it doesn't already exist (idk how expected it is for common registry values you'd actually configure to be missing by default?)
    # - maybe support value prefix for type? (ie. like .reg files do)...
    $registry_path = "Registry::${item_path}"
    $item = Get-Item -Path $registry_path -ErrorAction SilentlyContinue
    if (!$?) {
        $result.output = $Error[0].ToString()
        $result.status = 'failed'
        return $result
    }

    $existing_value = $item.GetValue($prop_name)
    if ($existing_value -ne $value) {
        Set-ItemProperty -Path $registry_path -Name $prop_name -Value $value `
            -ErrorAction SilentlyContinue
        if (!$?) {
            $result.output = $Error[0].ToString()
            $result.status = 'failed'
            return $result
        }
        $result.changed = $true
    }

    return $result
}

function registry_provision_state() {
    Param (
        [Parameter(Mandatory)]
        [object]$state,
        [string]$parent_key = ""
    )

    foreach ($prop in $state.PSObject.Properties) {
        $key = if ($parent_key.Equals("")) {
            $prop.Name
        }
        else {
            $prop_name = $prop.Name
            "${parent_key}\${prop_name}"
        }

        if ($prop.Value -is [PSObject]) {
            registry_provision_state $prop.Value -parent_key $key
        }
        else {
            registry_provision_key $key $prop.Value | ConvertTo-Json -Compress
        }
    }
}

function registry_provision() {
    $states = ConvertFrom-Json $stdin

    foreach ($state in $states) {
        registry_provision_state $state.state
    }
}

switch ($command) {
    "provision" {
        registry_provision
    }
    default {
        Write-Output "windows-registry: unrecognized subcommand: ${command}"
        exit 1
    }
}
