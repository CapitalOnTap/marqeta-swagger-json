# Imports
Import-Module "$($PSScriptRoot)\HelpersModule.ps1" -Force

Describe 'HelpersModule' {
    Context 'Invoke-DelegateOnJsonNode' {
        It "Runs" {
            $delegate = {
                Write-Host "Hello World."
            }
            Invoke-DelegateOnJsonNode -Delegate $delegate
        }
	}
	
	Context 'Invoke-DelegateOnJsonNodeWithProperty' {
        It "Runs" {
			[void][System.Reflection.Assembly]::LoadWithPartialName("System.Web.Extensions")
			$jsonObject = [System.Web.Script.Serialization.JavaScriptSerializer]::new().DeserializeObject((Get-Content -Path '.\swagger.json'))

			$delegate = {
				param (
					[string] $PropertyName,
					[object] $JsonObject
                )
                $value = $JsonObject[$PropertyName]
                if ($null -eq $value) {
                    $value = $JsonObject.$PropertyName
                }
				# Write-Host "$($PropertyName): '$($value)'."
            }
			
            Invoke-DelegateOnJsonNodeWithProperty -PropertyName "enum" -Delegate $delegate -JsonObject $jsonObject
        }
    }
}