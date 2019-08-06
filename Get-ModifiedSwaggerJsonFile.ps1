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
    Write-Verbose "Pre-paginated responses massaging."
    
    # /users/{parent_token}/children
    $jsonObject.paths['/users/{parent_token}/children'].get.responses['200'].schema.items.'$ref' = '#/definitions/user_card_holder_response'

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

    #
    # Incorrect responses
    #
    Write-Verbose "Fixing incorrect responses."

    #
    # /Incorrect responses
    #

    #
    # References to object type with no definitions
    #

    ## No existing definitions

    # advanced_simulation_response_model
    #   raw_iso8583
    # TODO: We should generate an ISO8583 type
    # $jsonObject.definitions['advanced_simulation_response_model'].properties.raw_iso8583.type = 'string'
    # $jsonObject.definitions['advanced_simulation_response_model'].properties.raw_iso8583.Remove('additionalProperties') | Out-Null

    # card_product
    #   velocityProfiles
    # $jsonObject.definitions['card_product'].properties.velocityProfiles.items.type = 'string'

    # Journal
    #   permissions
    # $jsonObject.definitions['Journal'].properties.permissions.items.type = 'string'
    #   layers
    # $jsonObject.definitions['Journal'].properties.layers.items.type = 'string'

    # mcc_group_model
    #   mccs
    $jsonObject.definitions['mcc_group_model'].properties.mccs.items.type = 'string'

    # Merchant
    #   externalInfo
    # $jsonObject.definitions['Merchant'].properties.externalInfo.type = 'string'
    # $jsonObject.definitions['Merchant'].properties.externalInfo.Remove('additionalProperties') | Out-Null

    # monitor_response
    #   metadata
    # $jsonObject.definitions['monitor_response'].properties.metadata.type = 'string'
    # $jsonObject.definitions['monitor_response'].properties.metadata.Remove('additionalProperties') | Out-Null
   
    # simulation_response_model
    #   raw_iso8583
    # TODO: We should generate an ISO8583 type
    # $jsonObject.definitions['simulation_response_model'].properties.raw_iso8583.type = 'string'
    # $jsonObject.definitions['simulation_response_model'].properties.raw_iso8583.Remove('additionalProperties') | Out-Null

    # TranLog
    #   followUps
    # $jsonObject.definitions['TranLog'].properties.followUps.items.type = 'string'

    ## Existing definitions

    # Brand
    #   campaigns
    $jsonObject.definitions['Brand'].properties.campaigns.items.'$ref' = '#/definitions/campaign_model'
    $jsonObject.definitions['Brand'].properties.campaigns.items.Remove('type') | Out-Null

    # Campaign
    #   dealDescriptors
    $jsonObject.definitions['Campaign'].properties.dealDescriptors.items.'$ref' = '#/definitions/DealDescriptor'
    $jsonObject.definitions['Campaign'].properties.dealDescriptors.items.Remove('type') | Out-Null

    # CardHolder
    #   accounts
    $jsonObject.definitions['CardHolder'].properties.accounts.type = 'array'
    $jsonObject.definitions['CardHolder'].properties.accounts.uniqueItems = $true
    $jsonObject.definitions['CardHolder'].properties.accounts.items = @{ '$ref' = '#/definitions/account_model' }
    $jsonObject.definitions['CardHolder'].properties.accounts.Remove('additionalProperties') | Out-Null

    # CompositeAccount
    #   children0
    $jsonObject.definitions['CompositeAccount'].properties.children0.items.'$ref' = '#/definitions/CompositeAccount'
    $jsonObject.definitions['CompositeAccount'].properties.children0.items.Remove('type') | Out-Null

    # CryptoKey
    #   zoneKeys
    $jsonObject.definitions['CryptoKey'].properties.zoneKeys.items.'$ref' = '#/definitions/CryptoKey'
    $jsonObject.definitions['CryptoKey'].properties.zoneKeys.items.Remove('type') | Out-Null
    #   cryptoKeys
    $jsonObject.definitions['CryptoKey'].properties.cryptoKeys.items.'$ref' = '#/definitions/CryptoKey'
    $jsonObject.definitions['CryptoKey'].properties.cryptoKeys.items.Remove('type') | Out-Null

    # FinalAccount
    #   children0
    $jsonObject.definitions['FinalAccount'].properties.children0.items.'$ref' = '#/definitions/CompositeAccount'
    $jsonObject.definitions['FinalAccount'].properties.children0.items.Remove('type') | Out-Null

    # Gatewaylog
    #   gatewayResponse
    $jsonObject.definitions['Gatewaylog'].properties.gatewayResponse.'$ref' = '#/definitions/gateway_response'
    $jsonObject.definitions['Gatewaylog'].properties.gatewayResponse.Remove('type') | Out-Null

    # GLTransaction
    #   entries
    $jsonObject.definitions['GLTransaction'].properties.entries.items.'$ref' = '#/definitions/GLEntry'
    $jsonObject.definitions['GLTransaction'].properties.entries.items.Remove('type') | Out-Null
    #   adjustmentEntries
    $jsonObject.definitions['GLTransaction'].properties.adjustmentEntries.items.'$ref' = '#/definitions/GLEntry'
    $jsonObject.definitions['GLTransaction'].properties.adjustmentEntries.items.Remove('type') | Out-Null

    # Merchant
    #   stores
    $jsonObject.definitions['Merchant'].properties.stores.items.'$ref' = '#/definitions/store_model'
    $jsonObject.definitions['Merchant'].properties.stores.items.Remove('type') | Out-Null
    #   terminals
    $jsonObject.definitions['Merchant'].properties.terminals.items.'$ref' = '#/definitions/terminal_model'
    $jsonObject.definitions['Merchant'].properties.terminals.items.Remove('type') | Out-Null

    # UserCardHolder
    #   accounts
    $jsonObject.definitions['UserCardHolder'].properties.accounts.type = 'array'
    $jsonObject.definitions['UserCardHolder'].properties.accounts.uniqueItems = $true
    $jsonObject.definitions['UserCardHolder'].properties.accounts.items = @{ '$ref' = '#/definitions/account_model' }
    $jsonObject.definitions['UserCardHolder'].properties.accounts.Remove('additionalProperties') | Out-Null

    #
    # /References to object type with no definitions
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
