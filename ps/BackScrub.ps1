[CmdletBinding(SupportsShouldProcess)]
Param (
    [System.IO.FileInfo]$BackupPath=$(Read-Host "Enter backup directory"),
    [System.IO.FileInfo]$LogPath=$(Read-Host "Enter log directory"),
    [int]$Days=60
)

#region import modules
@(
    'TSUtils'
) | Import-Module -Force -DisableNameChecking
#endregion

#region set globals
$global:Date = Get-Date -UFormat "%Y-%m-%d"
$global:Name = ($MyInvocation.MyCommand.Name) -Replace ".ps1",""
$global:Log  = "$LogPath\$Name-$Date.log"
#endregion

#region get users function
function Get-OldBackups {
    [CmdletBinding(SupportsShouldProcess)]
    Param (
	[Parameter(Mandatory)]
	[System.IO.FileInfo]$BackupPath,
	[Parameter(Mandatory)]
	[DateTime]$OlderThan
    )
    Get-ChildItem $BackupPath |
      Where-Object {
	  $_.Name -Match '^[A-z]+\.[A-z]+$|^[A-z]$'
      } | Select-Object -ExpandProperty Fullname |
	Get-ChildItem |
	Where-Object {
	    ($_.Name -match '^\d{4}\-\d{2}\-\d{2}') -And
	    ($_.LastWriteTime -lt $OlderThan) -And
	    ((Get-Date $_.Name) -lt $OlderThan)
	} | Select-Object -ExpandProperty Fullname
}
#endregion

#region delete old backups function
function Remove-OldBackups {
    [CmdletBinding(SupportsShouldProcess)]
    Param (
	[Parameter(Mandatory,ValueFromPipeline)]
	[string[]]$Path
    )

    begin {
	$Total = 0
    }

    process {
	Write-Host "Getting size of $Backup..."
	$Bytes = Get-DiskUsage $Backup -Bytes -ErrorAction SilentlyContinue
	$Size  = ConvertFrom-BytesToHumanReadable $Bytes
	Write-Host "Removing $Backup ($Size)..."
	Remove-Item $Backup -Recurse -Force -ErrorAction SilentlyContinue
	$Total += $Bytes
    }

    end {
	Write-Output $Total
    }
}
#endregion

#region main
Start-Transcript -Path $Log -Append
New-Path $LogPath -Type Directory
Write-Host "Finding backups older than $Days days under $BackupPath"
$OlderThan = ((Get-Date).AddDays(-$Days)).Date
$Total     = Get-OldBackups $BackupPath $OlderThan | Remove-OldBackups
$Total     = ConvertFrom-BytesToHumanReadable $Total
Write-Host "Successfully freed $Total."
Stop-Transcript
#endregion
