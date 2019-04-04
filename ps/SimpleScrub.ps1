[CmdletBinding(SupportsShouldProcess)]
Param (
    [System.IO.FileInfo]$Path=$(Read-Host "Enter a path"),
    [int]$Days=60,
    [switch]$Force
)

$Date = ((Get-Date).AddDays(-$Days)).Date

$Users = Get-ChildItem $Path |
  Where-Object {
      $_.Name -Match '^[A-z]+\.[A-z]+$|^[A-z]$'
  } | Select-Object -ExpandProperty Fullname

foreach ($User in $Users) {
    Get-ChildItem $User |
      Where-Object {
	  ($_.Name -match '^\d{4}\-\d{2}\-\d{2}') -And
	  ($_.LastWriteTime -lt $Date) -And
	  ((Get-Date $_.Name) -lt $Date)
      } | Select-Object -ExpandProperty Fullname |
	Remove-Item -Recurse -Force:($Force)
}
