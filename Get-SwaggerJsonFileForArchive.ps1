[CmdletBinding()]
param(
    [switch] $Clobber,
    [string] $File
)

# Timer
$sw = [System.Diagnostics.Stopwatch]::StartNew()

# Output settings
if (!$File) {
    $File = "./original-archive/swagger." + (Get-Date).ToString("yyyy.MM.dd") + ".json"
}
Write-Verbose "Using file '$($File)'."

# Download file
$defaultJsonUri = 'https://sandbox-api.marqeta.com/v3/swagger.json'
if ((Test-Path $File) -and !($Clobber)) {
    Write-Verbose "File '$($File)' already exists. Skipping."
}
else {
    Write-Verbose "Downloading '$defaultJsonUri'."
    Invoke-WebRequest -Uri $defaultJsonUri -OutFile $File
}

# Add to git
$gitCommand = Get-Command git -ErrorAction SilentlyContinue
if ($gitCommand) {
    Write-Verbose "Git accessible, staging '$($File)'."
    git add -A -f $File
}
else {
    Write-Verbose "Git inaccessible, skipping."
}

# Timer
$sw.Stop()
Write-Host "Swagger JSON archive completed in '$($sw.Elapsed)'." 
