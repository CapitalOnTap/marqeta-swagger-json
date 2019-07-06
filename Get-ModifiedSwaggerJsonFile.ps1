[CmdletBinding()]
param(
    [switch] $Clobber,
    [string] $File = './swagger.json'
)

# Timer
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Output settings
$outDir = $PSScriptRoot
Write-Verbose "Using `$outDir: $($outDir)"

#
# JSON Manipulation
#
# NB: Currently the marqeta-core-api/v3/swagger.json does not play well with code generation tools
#       like swagger-codegen or nswag. This is a temporary measure until this is resolved.
#
$defaultJsonUri = 'https://shared-sandbox-api.marqeta.com/v3/swagger.json'

Write-Verbose "Capping 'maxItems' values to 500."

if ((Test-Path $File) -and !($Clobber)) {
    Write-Verbose "File '$($File)' already exists. Skipping."
}
else {
    Write-Verbose "Downloading '$defaultJsonUri'."
    Invoke-WebRequest -Uri $defaultJsonUri -OutFile $File

    Write-Verbose 'Massaging JSON.'

    # Remove diacritics
    Write-Verbose 'Removing diacritics.'
    (Get-Content -Path $File).Replace("é", "e") | Out-File -Encoding utf8 $File

    # NB: We need to use the .NET JavaScriptSerializer because the build in powershell one cannot handle IDs with the same name but different casing
    [void][System.Reflection.Assembly]::LoadWithPartialName("System.Web.Extensions")
    $jsonObject = [System.Web.Script.Serialization.JavaScriptSerializer]::new().DeserializeObject((Get-Content -Path $File))

    # Title
    Write-Verbose "Adding 'title' property."
    $jsonObject.info.title = 'Marqeta Core Api'

    # NB: We change the max items due to a bug in swagger-codegen
    #       https://github.com/swagger-api/swagger-codegen/issues/6394
    Write-Verbose "Removing large 'maxItem' properties."
    $newMax = 500
    $jsonObject.definitions["auth_user_request"].properties["roles"].maxItems = $newMax
    $jsonObject.definitions["auth_user_update_request"].properties["roles"].maxItems = $newMax
    $jsonObject.definitions["commando_mode_enables"].properties["velocity_controls"].maxItems = $newMax

    #
    # Enum
    #       
    Write-Verbose "Removing problematic enums."
    Import-Module "$($PSScriptRoot)\HelpersModule.ps1" -Force
    $delegate = {
        param (
            [string] $PropertyName,
            [object] $JsonObject
        )

        # Early out if null
        if ($null -eq $JsonObject) { return }
        $value = $JsonObject[$PropertyName]
        if ($null -eq $value) { $value = $JsonObject.$PropertyName }
        if ($null -eq $value) { return }

        # If object is an array, recurse through array
        switch ($JsonObject.GetType().ToString()) {
            'System.Object[]' {
                $JsonObject | ForEach-Object { Invoke-DelegateOnJsonNodeWithProperty -PropertyName $PropertyName -Delegate $Delegate -JsonObject $_ }
                return
            }
        }

        #
        # Object is not an array so process object
        #

        # Blacklist - Remove enum value if it contains any of the following patterns
        $blacklist = @(
            '*Authentication*',
            '*char max*',
            '*chars max*',
            '*createdTime',
            '*created_time',
            '*user_transaction_time',
            '*max char*',
            '*max chars*',
            '*Must be * char*',
            '*Payment card or ACH account number*',
            '*Required if*',
            '*String representing batch id*',
            '*Strong password required*',
            '*Valid URL*',
            '*yyyy-MM-dd*'
            '*yyyyMMdd*'
        )
        foreach ($pattern in $blacklist) {
            if ($value -like $pattern) {
                $JsonObject.Remove($PropertyName) | Out-Null
                return
            }
        }

        # Arrays
        switch ($value.GetType().ToString()) {
            'System.Object[]' {
                if ($value.Length -eq 1) {
                    $delimiters = @('|', 'or', ' ')
                    $value1 = $value[0]
                    foreach ($delimiter in $delimiters) {
                        if ($value1.Contains($delimiter)) {
                            $newValue = $value1.Split($delimiter).Trim()
                            $JsonObject[$PropertyName] = $newValue
                            break
                        }
                    }
                }
                else {
                    $value1 = $value -like '*|*'
                    if ($value1) {
                        $newValue = $value1.Split('|').Trim()
                        $JsonObject[$PropertyName] = $newValue
                    }
                }
            }
        }

        # If the above manipulation has reduced the array to one or less items, remove it
        $value = $JsonObject[$PropertyName]
        switch ($value.GetType().ToString()) {
            'System.Object[]' {
                if ($value.Length -le 1) {
                    $JsonObject.Remove($PropertyName) | Out-Null
                    return
                }
            }
        }

        # Regex
        # Delete unsavory content within enumerations
        $regexes = @(
            [regex]::new("(\(default[ = ]*[0-9A-Za-z_]*\))")    # (default*)
            , [regex]::new("[^0-9A-Za-z_.]*")                   # Non alphanumeric characters - This should be done last
        )
        $newValue = $value `
        | ForEach-Object { 
            # Run each regex on the object and return it
            foreach ($regex in $regexes) { $_ = $regex.Replace($_, "") }
            $_
        } `
        | Where-Object { ![string]::IsNullOrWhiteSpace($_) } `
        | ForEach-Object { $_.Trim() }
        $JsonObject[$PropertyName] = $newValue
    }
    Invoke-DelegateOnJsonNodeWithProperty -PropertyName "enum" -Delegate $delegate -JsonObject $JsonObject
    #
    # /Enum
    #

    #
    # Remove operation ids
    #
    Write-Verbose "Removing problematic operation ids."
    $delegate = {
        param (
            [string] $PropertyName,
            [object] $JsonObject
        )

        # Early out if null
        if ($null -eq $JsonObject) { return }
        $value = $JsonObject[$PropertyName]
        if ($null -eq $value) { $value = $JsonObject.$PropertyName }
        if ($null -eq $value) { return }

        # If object is an array, recurse through array
        switch ($JsonObject.GetType().ToString()) {
            'System.Object[]' {
                $JsonObject | ForEach-Object { Invoke-DelegateOnJsonNodeWithProperty -PropertyName $PropertyName -Delegate $Delegate -JsonObject $_ }
                return
            }
        }

        # Object is not an array so process object
        $JsonObject.Remove($PropertyName) | Out-Null
    }
    Invoke-DelegateOnJsonNodeWithProperty -PropertyName "operationId" -Delegate $delegate -JsonObject $JsonObject
    #
    # /Remove operation ids
    #

    #
    # Paginated responses
    #
    Write-Verbose "Adding paginated responses."

    $paths = @(
        '/acceptedcountries'
        '/accountholdergroups'
        '/authcontrols'
        '/autoreloads'
        '/bulkissuances'
        '/businesses'
        '/campaigns'
        '/cardproducts'
        '/cards/user/{token}'
        '/chargebacks'
        '/commandomodes'
        '/digitalwallettokens'
        '/directdeposits'
        '/fees'
        '/fundingsources/addresses/business/{business_token}'
        '/fundingsources/addresses/user/{user_token}'
        '/fundingsources/program/ach'
        '/fundingsources/user/{user_token}'
        '/gpaorders/unloads'
        '/kyc/business/{business_token}'
        '/kyc/user/{user_token}'
        '/mccgroups'
        '/merchants'
        '/merchants/{token}/stores'
        '/msaorders/unloads'
        '/offers'
        '/programreserve/transactions'
        '/programtransfers'
        '/programtransfers/types'
        '/pushtocards/disburse'
        '/pushtocards/paymentcard'
        '/realtimefeegroups'
        '/stores'
        '/transactions'
        '/transactions/fundingsource/{funding_source_token}'
        '/transactions/{token}/related'
        '/usertransitions/user/{user_token}'
        '/users'
        '/users/phonenumber/{phone_number}'
        '/users/{parent_token}/children'
        '/users/{token}/notes'
        '/velocitycontrols'
        '/velocitycontrols/user/{user_token}/available'
        '/webhooks'
    )
    foreach ($path in $paths) {
        Write-Verbose "Adding paginated response for '$($path)'."

        $jsonResponse = $jsonObject.paths[$path].get.responses["200"]

        $responseSchema = $jsonResponse.schema
        if ($responseSchema.items) { $responseRefValue = $responseSchema.items['$ref'] }
        elseif ($responseSchema.'$ref') { $responseRefValue = $responseSchema.'$ref' }

        $modelName = $responseRefValue.Split('/') | Select-Object -Last 1
        $paginatedResponseName = $modelName + '_paginated_response'

        $jsonResponse.schema = @{
            '$ref' = '#/definitions/' + $paginatedResponseName;
        }
        $paginatedResponseSchema = @{
            'type'       = 'object';
            'properties' = @{
                'count'       = @{
                    'type'   = 'integer';
                    'format' = 'int32';
                };
                'start_index' = @{
                    'type'   = 'integer';
                    'format' = 'int32';
                };
                'end_index'   = @{
                    'type'   = 'integer';
                    'format' = 'int32';
                };
                'is_more'     = @{
                    'type' = 'boolean';
                };
                'data'        = @{
                    'type'  = 'array';
                    'items' = @{
                        '$ref' = '#/definitions/' + $modelName;
                    };
                }
            }
        }
        $jsonObject.definitions[$paginatedResponseName] = $paginatedResponseSchema
    }

    #
    # /Paginated responses
    #

    Write-Verbose "Writing file."
    $jsonObject | ConvertTo-Json -depth 100 | Out-File -Encoding utf8 $File
}

#
# /JSON Manipulation
#

# Timer
$sw.Stop()
Write-Host "Swagger JSON modification completed in '$($sw.Elapsed)'." 
