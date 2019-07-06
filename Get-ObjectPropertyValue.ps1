Function Get-ObjPropertyName {
<#
	.SYNOPSIS
		Search an object's (and sub-object's) property for a specific value. 
		Return property name and location.
	.DESCRIPTION
		Will recursivly go throw an object's 'Property' or 'NoteProperty' to find Value(s), even in nested Objects.
		Script reutns Name and Location of found value(s)
	.PARAMETER Object
		Object that will be searched for Value
	.PARAMETER Value
		Value to find in Object
	.PARAMETER ObjString
		String used for Invoke-Expression. This strings helps keep track of which property Value is found in
	.EXAMPLE
		#Create PSObject
		$Object = New-Object PSObject -Property @{ 
			Name = 'Test'
			Location = New-Object PSObject -Property @{ 
				IsPresent = $true
				HasValue = $true
				MoreProps = New-Object PSObject -Property @{
					IsDeep = $true
				}
				Namespace = 'System'
			}
		}			
		#Search for Object Property values that = $true
		Get-ObjPropertyName -Object $Object -value $true | FT -AutoSize
		
		Return:
		Name      Location                         
		----      --------                         
		IsDeep    $Object.Location.MoreProps.IsDeep
		HasValue  $Object.Location.HasValue        
		IsPresent $Object.Location.IsPresent 
		
	
#>
	param(
		[CmdletBinding()]
		[Parameter(Mandatory=$true)]$Object,
		[Parameter(Mandatory=$true)]$Value,
		[Parameter(Mandatory=$false)]$ObjString
	)
	if(!($ObjString)){
		$ObjString = '$Object'
	}
	$ErrorActionPreference = 'SilentlyContinue'
	$return = @()
	(Invoke-Expression -Command $ObjString -ErrorAction SilentlyContinue)  | Get-Member -View All | Where-Object { ($_.MemberType -like "Property") -or ($_.MemberType -like 'NoteProperty')} | ForEach-Object {
		Write-Verbose  $($ObjString + ".$PropertyName")
		$PropertyName = $_.Name
		If((Invoke-Expression -Command $ObjString).$PropertyName -like $value){
			$return += New-Object PSObject -Property @{ 
				Name = $PropertyName
				Location = $ObjString + ".$PropertyName"
			}
		}
		Get-ObjPropertyName -Object $Object -Value $value -ObjString $($ObjString + ".$PropertyName")
	}
	return $return
}