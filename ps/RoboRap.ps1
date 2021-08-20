Param (
    [Parameter(Mandatory=$True,Position=1)]
    [string]$SourceParent,
    [Parameter(Mandatory=$True,Position=2)]
    [string]$DestinationParent,
    [Parameter(Mandatory=$False,Position=3)]
    [switch]$AutomateUsers
)

# Set global variables.
$Host.PrivateData.ProgressForegroundColor = "Yellow"
$Host.PrivateData.ProgressBackgroundColor = "DarkBlue"
$Host.PrivateData.ErrorBackgroundColor    = "Black"
$Host.PrivateData.ErrorForegroundColor    = "Red"
$Host.PrivateData.VerboseBackgroundColor  = "Black"
$Host.PrivateData.VerboseForegroundColor  = "Yellow"
$Host.PrivateData.WarningBackgroundColor  = "Black"
$Host.PrivateData.WarningForegroundColor  = "Red"

function Set-Parents () {
    $global:SourceParent = $SourceParent
    $global:DestinationParent = $DestinationParent
}

function Set-OptParams () {
    if ($PSBoundParameters.ContainsKey('AutomateUsers')) {
	$global:AutomateUsers = $True
    } else {
	$global:AutomateUsers = $False
    }
}

function Set-CopyType () {
    # Set a flag/output string for determining whether we're backing up or restoring
    $SourceLetter = (Get-Item $SourceParent).PSDrive.Name
    $DestinationLetter = (Get-Item $DestinationParent).PSDrive.Name

    if ($DestinationLetter -match "F|B" -Or $DestinationParent -like "*Backups*") {
	$global:CopyType = "Backup"
    } elseif ($SourceLetter -match "F|B" -Or $SourceParent -like "*Backups*") {
	$global:CopyType = "Restore"
    } else {
	Write-Warning "Invalid path. Aborting."
	exit
    }
}

function Set-Users () {
    $global:Users = Get-LocalUser |
      ? { $_.Enabled -eq "True" -And $_.Name -notlike "default*" } |
      select -ExpandProperty Name
}

function Set-Globals () {
    Set-Parents
    Set-OptParams
    Set-CopyType
    Set-Users
}

# this function analyzes Robocopy's Log file and creates a powershell
# object based on it's summary.
function Get-RoboSummary ($Log) {
    $cellHeaders = @("Total", "Copied", "Skipped", "Mismatch", "Failed", "Extras")
    $rowTypes    = @("Dirs", "Files", "Bytes")
    # Extract rows
    $rows = cat $Log -Raw |
      Select-String -Pattern "(Dirs|Files|Bytes)\s*:(\s*([0-9]+(\.[0-9]+)?( [a-zA-Z]+)?)+)+" -AllMatches
    # Merge each row with its corresponding row type, with property Names of the cell headers
    for($x = 0; $x -lt $rows.Matches.Count; $x++) {
	$rowType  = $rowTypes[$x]
	$rowCells = $rows.Matches[$x].Groups[2].Captures | foreach{ $_.ToString().Trim() }
	$row = New-Object -TypeName PSObject
	$row | Add-Member -Type NoteProperty Type($rowType)
	for($i = 0; $i -lt $rowCells.Count; $i++) {
	    $header = $cellHeaders[$i]
	    $cell   = $rowCells[$i]
	    if ($separateUnits -and ($cell -match " ")) {
		$cell = $cell -split " "
	    }
	    $row | Add-Member -Type NoteProperty -Name $header -Value $cell
	}
	$row
    }
}

# this function uses the Get-RoboSummary function to analyse Robocopy's
# Log file and output useful information to the User.
function Check-Log ($Log) {
    $results = Get-RoboSummary -Log $Log
    foreach ($result in $results) {
	$type = $result.type
	$copied = $result.copied
	$failed = $result.failed
	if ($type -eq "Bytes") {
	    $gbCopied = [math]::Round($copied/1Gb, 2)
	    $gbFailed = [math]::Round($failed/1Gb, 2)
	    Write-Verbose "$copied $type/$gbCopied GB copied, $failed $type/$gbFailed GB failed"
	} else {
	    Write-Verbose "$copied $type copied, $failed $type failed"
	}
	if ($failed -gt 0) { $fail = $true }
    }
    if ($fail) {
	Write-Warning "Files skipped. Please see the Log."
	$report = cat $Log | gu | Select-String -pattern " Error [0-9]+ \([0-9]x[0-9]+\) "
	foreach ($line in $report) {
	    $line = $line -replace "\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} | \d+ \(\dx\d+\)| File"
	    Write-Verbose "$line"
	}
    } else {
	Write-Host -Back Black -Fore Green "Files successfully copied."
    }
}

# Robocopy wrapper that adds a progress bar by first running Robocopy
# with the list only parameter and Logging the output of that to a
# staging file that we add up the number of Bytes from using our
# Get-RoboSummary function.
#
# We then run our actual Robocopy job, wrapping it in a while loop,
# that compares the Bytes copied from it's Log every 2 seconds, to the
# total determined from the staging file.
#
# We calculate percentage, which we use when calling write-process
# from inside our loop.
#
# Finally the function runs checkLog to make sure all Files copied
# sucessfully.
function Copy-Directory ($Source, $Destination, $Log, $Stage) {
    #
    # Robocopy Params:
    #
    # /mir	= Mirror mode. equivalent to /e plus /purge
    # /np	= Don't show progress percentage in Log
    # /nc	= Don't Log file classes (existing, new file, etc.)
    # /ndl      = No Directory List - don't Log directory names.
    # /Bytes	= Show file sizes in Bytes
    # /njh	= Do not display Robocopy job header (JH)
    # /njs	= Do not display Robocopy job summary (JS)
    # /tee	= Display Log in stdout AND in target Log file
    # /e	= Copy Subfolders, including Empty Subfolders.
    # /xa	= Exclude Files with any of the given Attributes - s = system, h = hidden, t = temporary
    # /xd	= Exclude directories matching given names/paths.
    # /xf	= Exclude Files matching given names/paths/wildcards.
    # /xj	= Exclude junction points. (normally included by default).
    # /b	= Copy Files in Backup mode.
    # /r:n	= Number of Retries on failed copies - default is 1 million.
    # /w:n	= Wait time between retries - default is 30 seconds.
    # /mt:n	= Multithreaded copying, n = no. of threads to use (1-128), default = 8 threads, use of /LOG is recommended for better performance.
    # /j	= Copy using unbuffered I/O (recommended for large Files).
    # /z	= Copy Files in restartable mode (survive network glitch). Potential performance issues ... see https://serverfault.com/questions/812210/Robocopy-is-20x-slower-than-drag-droping-Files-between-servers
    # /Log	= Output status to LOG file (overwrite existing Log).
    # /ipg:n    = Inter-Packet Gap (ms), to free bandwidth on slow lines.
    # /l        = List only - don’t copy, timestamp or delete any Files.
    #
    $RoboParams = "/mir /nc /ndl /np /Bytes /r:2 /w:2 /mt:12"

    $Excludes = @(
	"/xj"
	"/xa:sht"
	"/xf *.ost"
	"/xf *.pst"
	"/xf .DS_Store"
	"/xf .localized"
	"/xf desktop.ini"
	"/xd AppData"
	"/xd MicrosoftEdgeBackups"
    )

    # Staging Robocopy Process
    Write-Host -Back Black -Fore magenta "Analysing Robocopy job..."
    Write-Verbose "SOURCE: $Source"
    Write-Verbose "DESTINATION: $Destination"
    Write-Verbose "OPTIONS: $RoboParams /l"
    Write-Verbose "LOG: $Stage"
    foreach ($Exclude in $Excludes) {
	if ($Exclude -Eq $Excludes[0]) {
	    Write-Verbose "EXCLUDES: $Exclude"
	} else {
	    Write-Verbose "          $Exclude"
	}
    }

    $StageParams = "$Source $Destination $RoboParams /l /Log:$Stage $Excludes"
    Write-Verbose "PARAMETERS: $StageParams"
    Start-Process -Wait -FilePath Robocopy.exe -ArgumentList $StageParams -WindowStyle Hidden

    $Bytes = Get-RoboSummary $Stage | ? { $_.Type -eq "Bytes" }
    $BytesTotal = $Bytes.copied
    $gbTotal = [math]::Round($BytesTotal/1Gb, 2)
    Write-Verbose "TOTAL: $BytesTotal Bytes, $gbTotal GB"
    # Check that there's actually anything to do. return if not.
    if ($BytesTotal -lt 1) {
	Write-Host -Back Black -Fore Green "No new or changed Files."
	return
    }

    # Actual Robocopy Process
    Write-Host -Back Black -Fore magenta "Starting Robocopy job..."
    Write-Verbose "SOURCE: $Source"
    Write-Verbose "DESTINATION: $Destination"
    Write-Verbose "OPTIONS: $RoboParams"
    Write-Verbose "LOG: $Log"
    foreach ($Exclude in $Excludes) {
	if ($Exclude -Eq $Excludes[0]) {
	    Write-Verbose "EXCLUDES: $Exclude"
	} else {
	    Write-Verbose "          $Exclude"
	}
    }

    $RealParams = "$Source $Destination $RoboParams /Log:$Log $Excludes"
    Write-Verbose "PARAMETERS: $RealParams"
    $RoboProcess = Start-Process -FilePath Robocopy.exe -ArgumentList $RealParams -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 500

    # Start progress bar loop if there's more than 256MB to copy
    while (!$RoboProcess.HasExited) {
	if ($gbTotal -gt 0.25) {
	    Start-Sleep -Milliseconds 2000

	    # trim blank lines, error lines and header and summary
	    $LogContent = cat -Path $Log | ? {$_.trim() -ne "" } |
	      Select-String -Pattern "^-{10,}$" -NotMatch |
	      Select-String -Pattern "ERROR: RETRY LIMIT EXCEEDED." -NotMatch |
	      Select-String -pattern " Error [0-9]+ \([0-9]x[0-9]+\) " -NotMatch |

	    Select-String -Pattern "The process cannot access the file because it is being used by another process." -NotMatch |
	      Select-String -Pattern "Waiting 2 seconds..." -NotMatch |
	      select -skip 12 | select -skiplast 6
	    $FilesCopied = $LogContent.Count

	    # catch first iteration exception
	    if ($FilesCopied -gt 0) {
		$RegexBytes = '(?<=\s+)\d+(?=\s+)'
		[Regex]::Matches($LogContent, $RegexBytes) | % {$BytesCopied = 0 } { $BytesCopied += $_.Value }
		$gbCopied = [math]::Round($BytesCopied/1Gb, 2)
	    }
	    if ($BytesCopied -gt 0 -And $BytesCopied -le $BytesTotal) {
		$percent = 0
		$percent = (($BytesCopied/$BytesTotal)*100)
		$percent = [math]::Round($percent, 2)
		Write-Progress -Activity "PROGRESS:" -CurrentOperation "$gbCopied of $gbTotal GB, $percent% Complete" -Status " " -PercentComplete $percent
	    }
	}
    }
    Write-Progress -Activity "PROGRESS:" -Status " " -Completed
    Check-Log -Log $Log
}

function Get-Variables ($User, $Path) {
    Write-Host -Back Black -Fore Cyan "$CopyType of $User started."
    $Date = (Get-Date).ToString('yyyy-MM-dd')
    if ($CopyType -eq "Backup") {
	$LogPath = "$DestinationParent\Logs\$CopyType\$User"
	$Log = "$LogPath\$Date.Log"
	$StagePath = "$LogPath\Stage"
	$Stage = "$StagePath\$Date.Log"
	$Source = $Path
	$Destination = "$DestinationParent\Users\$User"
	Make-Directory -path $StagePath
	Make-Directory -path $LogPath
	Make-Directory -path $Destination
	Copy-Directory -Source $Source -Destination $Destination -Log $Log -Stage $Stage
    } elseif ($CopyType -eq "Restore") {
	$LogPath = "$SourceParent\Logs\$CopyType\$User"
	$Log = "$LogPath\$Date.Log"
	$StagePath = "$LogPath\Stage"
	$Stage = "$StagePath\$Date.Stage.Log"
	$Source = "$SourceParent\Users\$User"
	$Destination = $Path
	Make-Directory -path $StagePath
	Make-Directory -path $LogPath
	Make-Directory -path $Destination
	Copy-Directory -Source $Source -Destination $Destination -Log $Log -Stage $Stage
    }
    Write-Host -Back Black -Fore Cyan "$CopyType of $User finished."
}

# function to test if directory exists and if it doesn't create it. if
# there's an error creating the directory we jump out of this
# iteration of the loop, since we don't want to backup or restore the
# parent.
function Make-Directory ($path) {
    if (-Not (Test-Path $path)) {
	try {
	    new-item -path $path -ItemType directory -ea stop | out-null
	} catch {
	    Write-Warning "Error creating $path - ABORTING."
	    continue
	}
    }
}

# Function to Get-Answer yes or no question.
function Get-Answer ($Question) {
    while ($true) {
	$Ans = Read-Host "$Question"
	switch -Regex ($ans) {
	    '^y(es)?$' { return $true }
	    '^n(o)?$' { return $false }
	    '^q(uit)?$' { exit 1 }
	    default {
		Write-Host "($ans) is invalid. Enter (y)es, (n)o or (q)uit."
	    }
	}
    }
}

# main "kickoff" functions
function Make-Parents () {
    Make-Directory -path $SourceParent
    Make-Directory -path $DestinationParent
}


function Copy-Users () {
    Write-Host -back black -fore green "`nUsers = $Users"

    foreach ($User in $Users) {
	$Path =  gwmi Win32_userprofile | ? { $_.LocalPath -like "*$User*" } | select -ExpandProperty LocalPath
	if (!$AutomateUsers) {
	    if (Get-Answer "`nWould you like to $CopyType $User") {
		Get-Variables -User $User -Path $Path
	    } else {
		Write-Host -Back Black -Fore Cyan "Skipping $User"
	    }
	} else {
	    Write-Host
	    Get-Variables -User $User -Path $Path
	}
	if ($User -eq $Users[-1]) { Write-Host }
    }
}

Set-Globals
Make-Parents
Copy-Users
