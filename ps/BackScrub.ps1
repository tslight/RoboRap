[CmdletBinding(SupportsShouldProcess)]
Param (
    [System.IO.FileInfo]$BackupPath=$(Read-Host "Enter backup directory"),
    [System.IO.FileInfo]$LogPath=$(Read-Host "Enter log directory"),
    [int]$Days=60,
    [switch]$Force
)

@(
    TSUtils
) | Import-Module -Force -DisableNameChecking

New-Path $LogPath
$Date = Get-Date -UFormat "%Y-%m-%d"
$Name = ($MyInvocation.MyCommand.Name) -Replace ".ps1",""
$Log = "$LogPath\$Name-$Date.log"

$OlderThan = ((Get-Date).AddDays(-$Days)).Date

Start-Transcript -Path $Log -Append

Write-Host "Finding old backups under $BackupPath"

$Users = Get-ChildItem $BackupPath |
  Where-Object {
      $_.Name -Match '^[A-z]+\.[A-z]+$|^[A-z]$'
  } | Select-Object -ExpandProperty Fullname

$Total = 0

foreach ($User in $Users) {
    $OldBackups = @(
	Get-ChildItem $User |
	  Where-Object {
	      ($_.Name -match '^\d{4}\-\d{2}\-\d{2}') -And
	      ($_.LastWriteTime -lt $OlderThan) -And
	      ((Get-Date $_.Name) -lt $OlderThan)
	  } | Select-Object -ExpandProperty Fullname
    )

    foreach ($Backup in $OldBackups) {
	Write-Host "Getting size of $Backup..."
	$Size = Get-DiskUsage $Backup -Bytes -ErrorAction SilentlyContinue
	Write-Host "Removing $Backup ($Size)..."
	Remove-Item $Backup -Recurse -Force:($Force)
	$Total += $Size
    }
}

$Total = ConvertFrom-BytesToHumanReadable $Total
Write-Host "Successfully freed $Total."

Stop-Transcript
