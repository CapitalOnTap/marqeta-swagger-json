[CmdletBinding()]
param(
    [switch] $Clobber,
    [switch] $DebugOutput,
    [string] $File = './swagger.json'
)

Function Out-JsonFile {
    param(
        [CmdletBinding()]
        [Parameter(Mandatory = $true)]$JsonObject,
        [Parameter(Mandatory = $true)]$FileName,
        [switch]$Unescape
    )

    # JSON string
    $content = ($JsonObject | ConvertTo-Json -depth 100)

    # Unescape if required
    if ($Unescape) {
        Write-Verbose "Writing file '$($FileName)' (unescaped)."
        $content = $content | ForEach-Object { [System.Text.RegularExpressions.Regex]::Unescape($_) }
    } else {
        Write-Verbose "Writing file '$($FileName)'."
    }

    # Output to file
    $content | Out-File -Encoding utf8 $FileName

    return;
}
Function Out-DebugJsonFile {
    param(
        [CmdletBinding()]
        [Parameter(Mandatory = $true)]$JsonObject,
        [Parameter(Mandatory = $true)][ref]$OutputCount
    )
    Out-JsonFile -JsonObject $JsonObject -FileName "./swagger.tmp.$($OutputCount.Value).json" -Unescape
    $OutputCount.Value += 1
    return;
}


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
$defaultJsonUri = 'https://sandbox-api.marqeta.com/v3/swagger.json'

Write-Verbose "Capping 'maxItems' values to 500."

if ((Test-Path $File) -and !($Clobber)) {
    Write-Verbose "File '$($File)' already exists. Skipping."
}
else {
    Write-Verbose "Downloading '$defaultJsonUri'."
    Invoke-WebRequest -Uri $defaultJsonUri -OutFile $File

    Write-Verbose 'Massaging JSON.'

    # NB: We need to use the .NET JavaScriptSerializer because the build in powershell one cannot handle IDs with the same name but different casing
    [void][System.Reflection.Assembly]::LoadWithPartialName("System.Web.Extensions")
    $jsonObject = [System.Web.Script.Serialization.JavaScriptSerializer]::new().DeserializeObject((Get-Content -Path $File))

    # Debug output
    $debugTmpFileCount = 0
    if ($DebugOutput) {
        Out-DebugJsonFile -JsonObject $jsonObject -OutputCount ([ref]$debugTmpFileCount)
    }

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

    # Debug output
    if ($DebugOutput) {
        Out-DebugJsonFile -JsonObject $jsonObject -OutputCount ([ref]$debugTmpFileCount)
    }

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

    # Debug output
    if ($DebugOutput) {
        Out-DebugJsonFile -JsonObject $jsonObject -OutputCount ([ref]$debugTmpFileCount)
    }

    # Add missing enum values
    Write-Verbose "Adding missing enum values."

    # Add Unknown values
    $unknownValue = 'UNKNOWN'

    # definitions/pos/pos_pan_entry_mode
    $enum = $jsonObject.definitions['pos'].properties.pan_entry_mode.enum
    if ($enum -notcontains $unknownValue) {
        $enum += $unknownValue
        $jsonObject.definitions['pos'].properties.pan_entry_mode.enum = $enum
        Write-Verbose "Added '$($unknownValue)' to 'definitions/pos/pan_entry_mode'."
    }

    # /definitions/pos/properties/pin_entry_mode/enum
    $enum = $jsonObject.definitions['pos'].properties.pin_entry_mode.enum
    if ($enum -notcontains $unknownValue) {
        $enum += $unknownValue
        $jsonObject.definitions['pos'].properties.pin_entry_mode.enum = $enum
        Write-Verbose "Added '$($unknownValue)' to 'definitions/pos/pin_entry_mode'."
    }

    # definitions/pos/card_data_input_capability
    $enum = $jsonObject.definitions['pos'].properties.card_data_input_capability.enum
    $poscdic = ($enum + $('BAR_CODE') | Select-Object -Unique) # Add missing BAR_CODE
    $jsonObject.definitions['pos'].properties.card_data_input_capability.enum = $poscdic
    if ($enum -notcontains $unknownValue) {
        $jsonObject.definitions['pos'].properties.card_data_input_capability.enum += $unknownValue
        $enum += $unknownValue
        Write-Verbose "Added '$($unknownValue)' to 'definitions/pos/card_data_input_capability'."
    }

    # definitions/digital_wallet_token_transition_response/channel
    $enum = $jsonObject.definitions['digital_wallet_token_transition_response'].properties.channel.enum
    $dwttrc = ($enum + $('TOKEN_SERVICE_PROVIDER_API') | Select-Object -Unique) # Add missing TOKEN_SERVICE_PROVIDER_API
    $jsonObject.definitions['digital_wallet_token_transition_response'].properties.channel.enum = $dwttrc    

    # Update values
    $currentTransactionTypes = $jsonObject.definitions['transaction_model'].properties.type.enum
    $ttUnion = ($currentTransactionTypes + $requiredTransactionEventTypes | Select-Object -Unique) | Sort-Object
    $jsonObject.definitions['transaction_model'].properties.type.enum = $ttUnion
    
    # Output difference for reporting purposes
    $ttDelta = ($requiredTransactionEventTypes | Where-Object { $currentTransactionTypes -notcontains $_ })
    if ($ttDelta -and ($ttDelta.Count -ge 1)) {
        Write-Verbose "Added $($ttDelta.Count) transaction types:"
        Write-Verbose "$($ttDelta)"
    }
    else {
        Write-Verbose "Transaction Types valid, not changes made."
    }

    # Debug output
    if ($DebugOutput) {
        Out-DebugJsonFile -JsonObject $jsonObject -OutputCount ([ref]$debugTmpFileCount)
    }


    # Transaction Event Types
    # NB: Taken from https://www.marqeta.com/docs/core-api/event-types on 2019/10/09
    Write-Verbose "Validating Transaction Event Types."
    $requiredTransactionEventTypes = @(
        'account.credit',
        'account.debit',
        # The above were removed from Marqeta's documentation as of 2019.10.09. We are keeping them in case this was not intended... 
        'account.funding.auth_plus_capture',
        'account.funding.auth_plus_capture.reversal',
        'account.funding.authorization',
        'account.funding.authorization.clearing',		
        'account.funding.authorization.reversal',		
        'authorization',
        'authorization.advice',
        'authorization.atm.withdrawal',
        'authorization.cashback',
        'authorization.clearing',
        'authorization.clearing.atm.withdrawal',
        'authorization.clearing.cashback',
        'authorization.clearing.chargeback',
        'authorization.clearing.chargeback.completed',
        'authorization.clearing.chargeback.provisional.credit',
        'authorization.clearing.chargeback.provisional.debit',
        'authorization.clearing.chargeback.reversal',
        'authorization.clearing.chargeback.writeoff',
        'authorization.clearing.quasi.cash',
        'authorization.clearing.representment',
        'authorization.incremental',
        'authorization.quasi.cash',
        'authorization.reversal',
        'authorization.reversal.issuerexpiration',
        'authorization.standin',
        'address.verification',
        # Added to fix api desrelization
        'balanceinquiry',
        'billpayment',
        'billpayment.clearing',
        'billpayment.reversal',
        'directdeposit.credit',
        'directdeposit.credit.pending',
        'directdeposit.credit.pending.reversal',
        'directdeposit.credit.reject',		
        'directdeposit.credit.reversal',
        'directdeposit.debit',
        'directdeposit.debit.pending',
        'directdeposit.debit.pending.reversal',
        'directdeposit.debit.reject',
        'directdeposit.debit.reversal',		
        'fee.charge',
        'fee.charge.pending',
        'fee.charge.reversal',
        'gpa.credit',
        'gpa.credit.authorization',
        'gpa.credit.authorization.billpayment',
        'gpa.credit.authorization.billpayment.reversal',
        'gpa.credit.authorization.reversal',
        'gpa.credit.billpayment',
        'gpa.credit.issueroperator',
        'gpa.credit.networkload',
        'gpa.credit.networkload.reversal',
        'gpa.credit.pending',
        'gpa.credit.pending.reversal',
        'gpa.credit.reversal',
        'gpa.debit',
        'gpa.debit.issueroperator',
        'gpa.debit.reversal',
        'msa.credit',
        'msa.credit.pending',
        'msa.credit.pending.reversal',
        'msa.credit.reversal',
        'msa.debit',
        'original.credit.auth_plus_capture',
        'original.credit.auth_plus_capture.reversal',
        'original.credit.authorization',
        'original.credit.authorization.clearing',
        'original.credit.authorization.reversal',
        'pindebit',
        'pindebit.atm.withdrawal',
        'pindebit.authorization',
        'pindebit.authorization.clearing',
        'pindebit.authorization.reversal.issuerexpiration',
        'pindebit.balanceinquiry',
        'pindebit.cashback',
        'pindebit.chargeback',
        'pindebit.chargeback.completed',
        'pindebit.chargeback.provisional.credit',
        'pindebit.chargeback.provisional.debit',
        'pindebit.chargeback.reversal',
        'pindebit.chargeback.writeoff',
        'pindebit.credit.adjustment',
        'pindebit.quasicash',
        'pindebit.refund',
        'pindebit.refund.reversal',
        'pindebit.reversal',
        'pindebit.transfer',
        'programreserve.credit',
        'programreserve.debit',
        'pushtocard.debit',
        'pushtocard.reversal',
        'refund',
        'refund.authorization',
        'refund.authorization.clearing',
        'refund.authorization.reversal',
        'token.activation-request',
        'token.advice',
        'transaction.unknown',
        'transfer.fee',
        'transfer.peer',
        'transfer.program',
        'unknown'
    )

    # Update values
    $currentTransactionTypes = $jsonObject.definitions['transaction_model'].properties.type.enum
    $ttUnion = ($currentTransactionTypes + $requiredTransactionEventTypes | Select-Object -Unique) | Sort-Object
    $jsonObject.definitions['transaction_model'].properties.type.enum = $ttUnion
    
    # Output difference for reporting purposes
    $ttDelta = ($requiredTransactionEventTypes | Where-Object { $currentTransactionTypes -notcontains $_ })
    if ($ttDelta -and ($ttDelta.Count -ge 1)) {
        Write-Verbose "Added $($ttDelta.Count) transaction types:"
        Write-Verbose "$($ttDelta)"
    }
    else {
        Write-Verbose "Transaction Types valid, not changes made."
    }

    # Remove unrequired enums
    $jsonObject.definitions['card_response'].properties.last_four.Remove('enum') | Out-Null
    $jsonObject.definitions['card_transition_response'].properties.last_four.Remove('enum') | Out-Null

    $cardTransitionResponseStates = $jsonObject.definitions['card_transition_response'].properties.state.enum
    $ctR = ($cardTransitionResponseStates + $('UNACTIVATED') | Select-Object -Unique) | Sort-Object
    $jsonObject.definitions['card_transition_response'].properties.state.enum = $ctR

    $currentPaymentChannels = $jsonObject.definitions['transaction_metadata'].properties.payment_channel.enum
    $unionPaymentChannels = ($currentPaymentChannels + $('MOTO') | Select-Object -Unique) | Sort-object
    $jsonObject.definitions['transaction_metadata'].properties.payment_channel.enum = $unionPaymentChannels

    $currentPanEntryMode = $jsonObject.definitions['pos'].properties.pan_entry_mode.enum
    $unionPanEntryMode = $($currentPanEntryMode + $('CARD_ON_FILE') | Select-Object -Unique) | Sort-Object
    $jsonObject.definitions['pos'].properties.pan_entry_mode.enum = $unionPanEntryMode

    # Debug output
    if ($DebugOutput) {
        Out-DebugJsonFile -JsonObject $jsonObject -OutputCount ([ref]$debugTmpFileCount)
    }

    #
    # /Enum
    #

    #
    # Incorrect Types
    #
    $jsonObject.definitions['pos'].properties.pin_present = @{
                'type' = 'boolean';
            };
    #
    # /Incorrect Types
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

    # Debug output
    if ($DebugOutput) {
        Out-DebugJsonFile -JsonObject $jsonObject -OutputCount ([ref]$debugTmpFileCount)
    }

    #
    # /Remove operation ids
    #

    #
    # Paginated responses
    #
    Write-Verbose "Pre-paginated responses massaging."

    Write-Verbose "Adding paginated responses."
    $paths = @(
        '/cards/user/{token}'
        '/fees'
        '/fundingsources/program/ach'
        '/programreserve/transactions'
        '/realtimefeegroups'
        '/transactions'
        '/transactions/fundingsource/{funding_source_token}'
        '/transactions/{token}/related'
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

    # Debug output
    if ($DebugOutput) {
        Out-DebugJsonFile -JsonObject $jsonObject -OutputCount ([ref]$debugTmpFileCount)
    }

    #
    # /Paginated responses
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

    # Gatewaylog
    #   gatewayResponse
    Write-Verbose "Adding '#/definitions/gateway_response' ref to '#/definitions/Gatewaylog'."
    $jsonObject.definitions['Gatewaylog'].properties.gatewayResponse.'$ref' = '#/definitions/gateway_response'
    $jsonObject.definitions['Gatewaylog'].properties.gatewayResponse.Remove('type') | Out-Null

    # Debug output
    if ($DebugOutput) {
        Out-DebugJsonFile -JsonObject $jsonObject -OutputCount ([ref]$debugTmpFileCount)
    }

    #
    # /References to object type with no definitions
    #

    #
    # Definitions: missing properties
    #

    Write-Verbose "Adding missing properties to definitions."

    $missingProperties = @(
        # Please keep these values in a alphabetical order based on the following fields in order of precedence: Definition, PropertyName
        @{ Definition = 'response'; PropertyName = 'additional_information'; PropertyValue = @{'type' = 'string' }; }
        , @{ Definition = 'transaction_model'; PropertyName = 'card_acceptor'; PropertyValue = @{ '$ref' = '#/definitions/transaction_card_acceptor' }; }
        , @{ Definition = 'transaction_model'; PropertyName = 'pos'; PropertyValue = @{ '$ref' = '#/definitions/pos' }; }
        , @{ Definition = 'transaction_model'; PropertyName = 'transaction_metadata'; PropertyValue = @{ '$ref' = '#/definitions/transaction_metadata' }; }
        , @{ Definition = 'card_holder_model'; PropertyName = 'status'; PropertyValue = @{ 'type' = 'string'; 'enum' = @('UNVERIFIED', 'LIMITED', 'ACTIVE', 'SUSPENDED', 'CLOSED')  }; }
        , @{ Definition = 'network'; PropertyName = 'conversion_rate'; PropertyValue = @{ 'type' = 'number' }; }
        , @{ Definition = 'network'; PropertyName = 'original_amount'; PropertyValue = @{ 'type' = 'number' }; }
        , @{ Definition = 'network'; PropertyName = 'original_currency_code'; PropertyValue = @{ 'type' = 'string' }; }
    )
    foreach ($missingProperty in $missingProperties) {
        if ($null -eq $jsonObject.definitions[$missingProperty.Definition].properties."$($missingProperty.PropertyName)") {
            Write-Verbose "Adding '$($missingProperty.PropertyName)' to '$($missingProperty.Definition)'."
            $jsonObject.definitions[$missingProperty.Definition].properties.Add($missingProperty.PropertyName, $missingProperty.PropertyValue)
        }
    }

    # Debug output
    if ($DebugOutput) {
        Out-DebugJsonFile -JsonObject $jsonObject -OutputCount ([ref]$debugTmpFileCount)
    }

    #
    # /Definitions: missing properties
    #

    #
    # Definitions: Blanket deletion
    #

    $definitionsToRemove = @(
        'fraud'
        , 'issuer'
    )
    foreach ($definitionToRemove in $definitionsToRemove) {
        Write-Verbose ("Removing definition '" + $definitionToRemove + "'.")
        $jsonObject.definitions.Remove($definitionToRemove) | Out-Null
    }

    # Debug output
    if ($DebugOutput) {
        Out-DebugJsonFile -JsonObject $jsonObject -OutputCount ([ref]$debugTmpFileCount)
    }

    #
    # /Definitions: Blanket deletion
    #

    #
    # Definitions: missing definitions
    #

    Write-Verbose "Adding missing definitions."

    # currency_conversion_network
    $currencyConversionNetworkSchema = @{
        'type'       = 'object';
        'properties' = @{
            'original_amount'        = @{
                'type' = 'number';
            };
            'conversion_rate'        = @{
                'type' = 'number';
            };
            'original_currency_code' = @{
                'type' = 'string';
            };
        }
    }
    $jsonObject.definitions['currency_conversion_network'] = $currencyConversionNetworkSchema

    # fraud
    $fraudSchema = @{
        'type'       = 'object';
        'properties' = @{
            'issuer_processor' = @{
                '$ref' = '#/definitions/issuer_processor';
            };
            'network'          = @{
                '$ref' = '#/definitions/fraud_network';
            };
        }
    }
    $jsonObject.definitions['fraud'] = $fraudSchema

    # fraud_network
    $fraudNetworkSchema = @{
        'type'       = 'object';
        'properties' = @{
            'account_risk_score'                        = @{
                'type' = 'number';
            };
            'account_risk_score_reason_code'            = @{
                'type' = 'string';
            };
            'merchant_risk_score'                       = @{
                'type' = 'number';
            };
            'merchant_risk_score_reason_code'           = @{
                'type' = 'string';
            };
            'transaction_risk_score'                    = @{
                'type' = 'number';
            };
            'transaction_risk_score_reason_code'        = @{
                'type' = 'string';
            };
            'transaction_risk_score_reason_description' = @{
                'type' = 'string';
            };
        }
    }
    $jsonObject.definitions['fraud_network'] = $fraudNetworkSchema

    # issuer_processor
    $issuerProcessorSchema = @{
        'type'       = 'object';
        'properties' = @{
            'score'              = @{
                'type' = 'number';
            };
            'risk_level'         = @{
                'type' = 'string';
            };
            'recommended_action' = @{
                'type' = 'string'; 
            };
            'rule_violations'    = @{
                'type'  = 'array';
                'items' = @{
                    'type' = 'string';
                };
            }
        }
    }
    $jsonObject.definitions['issuer_processor'] = $issuerProcessorSchema

    # Debug output
    if ($DebugOutput) {
        Out-DebugJsonFile -JsonObject $jsonObject -OutputCount ([ref]$debugTmpFileCount)
    }

    #
    # /Definitions: missing definitions
    #

    #
    # Definitions: incorrectly named properties
    #

    Write-Verbose "Fixing incorrectly named definition properties."

    # Comment kept as an example
    # transaction_model
    #   issuer_interchange_amount
    #$jsonObject.definitions['transaction_model'].properties.Remove('issuerInterchangeAmount') | Out-Null
    #$jsonObject.definitions['transaction_model'].properties.Add('issuer_interchange_amount', @{ 'type' = 'number' })
    
    # Debug output
    if ($DebugOutput) {
        Out-DebugJsonFile -JsonObject $jsonObject -OutputCount ([ref]$debugTmpFileCount)
    }

    #
    # /Definitions: incorrectly named properties
    #

    Out-JsonFile -JsonObject $jsonObject -FileName $File
}

#
# /JSON Manipulation
#

# Timer
$sw.Stop()
Write-Host "Swagger JSON modification completed in '$($sw.Elapsed)'." 
