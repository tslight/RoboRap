# this script takes two parameters - a source directory parent and a destination directory parent.
Param (
    [Parameter(Mandatory=$True,Position=1)]
    [string]$srcParent,
    [Parameter(Mandatory=$True,Position=2)]
    [string]$destParent,
    [Parameter(Mandatory=$False,Position=3)]
    [switch]$automateUsers,
    [Parameter(Mandatory=$False,Position=4)]
    [switch]$automateExcludes
)

if ($PSBoundParameters.ContainsKey('automateUsers')) {
    $global:automateUsers=$True
} else {
    $global:automateUsers=$False
}

if ($PSBoundParameters.ContainsKey('automateExcludes')) {
    $global:automateExcludes=$True
} else {
    $global:automateExcludes=$False
}

function get_excludes ($excludes_hash) {
    $excludes = @()

    $appdata_excludes = [ordered]@{
	"AppData CrashDumps" = "/xd AppData\Local\CrashDumps"
	"Google AppData"     = "/xd AppData\Local\Google"
	"Microsoft AppData"  = "/xd AppData\Local\Microsoft"
	"Mozilla AppData"    = "/xd AppData\Local\Mozilla"
	"Package AppData"    = "/xd AppData\Local\Packages"
	"Temporary AppData"  = "/xd AppData\Local\Temp"
    }

    $dot_excludes = [ordered]@{
	"Emacs Config"	= "/xd .emacs.d"
	"Dot Cache"	= "/xd .cache"
	"Dot Config"	= "/xd .config"
	"Dot Local"	= "/xd .local"
	"SSH Config"	= "/xd .ssh"
    }

    foreach ($exclude in $excludes_hash.keys) {
	if (ask "Exclude $exclude") {
	    $excludes += $excludes_hash[$exclude]
	} else {
	    if ($exclude -match "^AppData$") {
		get_excludes $appdata_excludes
	    }
	    if ($exclude -match "^Dot Directories$") {
		get_excludes $dot_excludes
	    }
	}
    }
    return $excludes
}

# this function analyzes robocopy's log file and creates a powershell
# object based on it's summary.
function roboSummary ($log) {
    $cellHeaders = @("Total", "Copied", "Skipped", "Mismatch", "Failed", "Extras")
    $rowTypes    = @("Dirs", "Files", "Bytes")
    # Extract rows
    $rows = cat $log -Raw | Select-String -Pattern "(Dirs|Files|Bytes)\s*:(\s*([0-9]+(\.[0-9]+)?( [a-zA-Z]+)?)+)+" -AllMatches
    # Merge each row with its corresponding row type, with property names of the cell headers
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

# this function uses the roboSummary function to analyse robocopy's
# log file and output useful information to the user.
function checkLog ($log) {
    $results = roboSummary -log $log
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
	Write-Host -back black -fore red  "Files skipped. Please see the log."
	$report = cat $log | gu | Select-String -pattern " Error [0-9]+ \([0-9]x[0-9]+\) "
	foreach ($line in $report) {
	    $line = $line -replace "\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2} | \d+ \(\dx\d+\)| File"
	    Write-Verbose "$line"
	}
    } else {
	Write-Host -back black -fore green "Files successfully copied."
    }
}

function copyDirectory ($src, $dest, $log, $stage) {
    #
    # Robocopy Params:
    #
    # /mir	= Mirror mode
    # /np	= Don't show progress percentage in log
    # /nc	= Don't log file classes (existing, new file, etc.)
    # /ndl      = No Directory List - don't log directory names.
    # /bytes	= Show file sizes in bytes
    # /njh	= Do not display robocopy job header (JH)
    # /njs	= Do not display robocopy job summary (JS)
    # /tee	= Display log in stdout AND in target log file
    # /e	= Copy Subfolders, including Empty Subfolders.
    # /xa	= Exclude files with any of the given Attributes - s = system, h = hidden, t = temporary
    # /xd	= Exclude directories matching given names/paths.
    # /xf	= Exclude files matching given names/paths/wildcards.
    # /xj	= Exclude junction points. (normally included by default).
    # /b	= Copy files in Backup mode.
    # /r:n	= Number of Retries on failed copies - default is 1 million.
    # /w:n	= Wait time between retries - default is 30 seconds.
    # /mt:n	= Multithreaded copying, n = no. of threads to use (1-128), default = 8 threads, use of /LOG is recommended for better performance.
    # /j	= Copy using unbuffered I/O (recommended for large files).
    # /z	= Copy files in restartable mode (survive network glitch). Potential performance issues ... see https://serverfault.com/questions/812210/robocopy-is-20x-slower-than-drag-droping-files-between-servers
    # /log	= Output status to LOG file (overwrite existing log).
    # /ipg:n    = Inter-Packet Gap (ms), to free bandwidth on slow lines.
    # /l        = List only - don’t copy, timestamp or delete any files.
    #
    $rargs = "/e /nc /ndl /np /bytes /r:2 /w:2 /mt:12"

    if ($AutomateExcludes) {
	$opt_excludes = @(
	    "/xd AppData\Local\CrashDumps"
	    "/xd AppData\Local\Microsoft"
	    "/xd AppData\Local\Packages"
	    "/xd AppData\Local\Temp"
	)
    } else {
	$home_excludes = [ordered]@{
	    "Junction Points" = "/xj"
	    "Dot Files"	      = "/xf .*"
	    "Dot Directories" = "/xd .*"
	    "AppData"	      = "/xd AppData"
	    "Downloads"	      = "/xd Downloads"
	    "iTunes"          = "/xd *iTunes* /xf *iTunes*"
	    "OneDrive"        = "/xd OneDrive"
	}
	$opt_excludes = get_excludes $home_excludes
    }

    $default_excludes = @(
	"/xa:sht"
	"/xf *.ost"
	"/xf *.pst"
	"/xf desktop.ini"
	"/xf .DS_Store"
    )

    # Staging Robocopy Process
    Write-Host -back black -fore magenta "Analysing Robocopy job..."
    Write-Verbose "SRC: $src"
    Write-Verbose "DEST: $dest"
    Write-Verbose "ARGS: $rargs /l"
    Write-Verbose "LOG: $stage"
    Write-Verbose "EXCLUDES: $default_excludes $opt_excludes"
    Write-Verbose "ALL: $src $dest $rargs /l /log:$stage $opt_excludes $default_excludes"

    $stageArgs = "$src $dest $rargs /l /log:$stage $opt_excludes $default_excludes"
    Start-Process -FilePath robocopy.exe -ArgumentList $stageArgs -WindowStyle Hidden -Wait

    $bytes = roboSummary -log $stage | ? { $_.Type -eq "Bytes" }
    $bytesTotal = $bytes.copied
    $gbTotal = [math]::Round($bytesTotal/1Gb, 2)
    Write-Verbose "TOTAL: $bytesTotal Bytes, $gbTotal GB"
    if ($bytesTotal -lt 1) {
	Write-Host -back black -fore Green "No new or changed files."
	return
    }

    # Actual Robocopy Process
    Write-Host -back black -fore magenta "Starting Robocopy job..."
    Write-Verbose "SRC: $src"
    Write-Verbose "DEST: $dest"
    Write-Verbose "ARGS: $rargs"
    Write-Verbose "LOG: $log"
    Write-Verbose "EXCLUDES: $default_excludes $opt_excludes"
    Write-Verbose "ALL: $src $dest $rargs /log:$log $opt_excludes $default_excludes"

    $roboArgs = "$src $dest $rargs /log:$log $default_excludes $opt_excludes"
    $roboProcess = Start-Process -FilePath robocopy.exe -ArgumentList $roboArgs -PassThru -WindowStyle Hidden
    Start-Sleep -Milliseconds 500

    # Start progress bar loop if there's more than 256MB to copy
    while (!$roboProcess.HasExited) {
	if ($gbTotal -gt 0.25) {
	    Start-Sleep -Milliseconds 2000

	    # trim blank lines, error lines and header and summary
	    $logContent = cat -Path $log | ? {$_.trim() -ne "" } |
	      Select-String -Pattern "^-{10,}$" -NotMatch |
	      Select-String -Pattern "ERROR: RETRY LIMIT EXCEEDED." -NotMatch |
	      Select-String -pattern " Error [0-9]+ \([0-9]x[0-9]+\) " -NotMatch |
	      Select-String -Pattern "The process cannot access the file because it is being used by another process." -NotMatch |
	      Select-String -Pattern "Waiting 2 seconds..." -NotMatch |
	      select -skip 12 | select -skiplast 6
	    $filesCopied = $logContent.Count

	    # catch first iteration exception
	    if ($filesCopied -gt 0) {
		$regexBytes = '(?<=\s+)\d+(?=\s+)'
		[Regex]::Matches($logContent, $regexBytes) | % {$bytesCopied = 0 } { $bytesCopied += $_.Value }
		$gbCopied = [math]::Round($bytesCopied/1Gb, 2)
	    }
	    if ($bytesCopied -gt 0 -And $bytesCopied -le $bytesTotal) {
		$percent = 0
		$percent = (($bytesCopied/$bytesTotal)*100)
		$percent = [math]::Round($percent, 2)
		$host.privatedata.ProgressForegroundColor = "Yellow"
		$host.privatedata.ProgressBackgroundColor = "DarkBlue"
		Write-Progress -Activity "PROGRESS:" -CurrentOperation "$gbCopied of $gbTotal GB, $percent% Complete" -Status " " -PercentComplete $percent
	    }
	}
    }
    Write-Progress -Activity "PROGRESS:" -Status " " -Completed
    checkLog -log $log
}

# Function to ask yes or no question.
function ask ($question) {
    while ($true) {
	$ans = Read-Host "$question"
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

function copyWrap ($copyType, $srcParent, $destParent, $user) {
    Write-Host -back black -fore cyan "$copyType of $user started."
    if ($copyType -eq "Backup") {
	$date = (Get-Date).ToString('yyyy-MM-dd')
	$logPath = "$destParent\Logs\$copyType\$user"
	$log = "$logPath\$date.log"
	$stagePath = "$logPath\stage"
	$stage = "$stagePath\$date.log"
	$src = $path
	$dest = "$destParent\Users\$user"
	makeDirectory -path $stagePath
	makeDirectory -path $logPath
	makeDirectory -path $dest
	copyDirectory -src $src -dest $dest -log $log -stage $stage
    } elseif ($copyType -eq "Restore") {
	$date = (Get-Date).ToString('yyyy-MM-dd')
	$logPath = "$srcParent\Logs\$copyType\$user"
	$log = "$logPath\$date.log"
	$stagePath = "$logPath\stage"
	$stage = "$stagePath\$date.stage.log"
	$src = "$srcParent\Users\$user"
	$dest = $path
	makeDirectory -path $stagePath
	makeDirectory -path $logPath
	makeDirectory -path $dest
	copyDirectory -src $src -dest $dest -log $log -stage $stage
    }
    Write-Host -back black -fore cyan "$copyType of $user finished."
}

# function to test if directory exists and if it doesn't create it. if
# there's an error creating the directory we jump out of this
# iteration of the loop, since we don't want to backup or restore the
# parent.
function makeDirectory ($path) {
    if (-Not (Test-Path $path)) {
	try {
	    new-item -path $path -ItemType directory -ea stop | out-null
	} catch {
	    Write-Host -back black -fore Red "Error creating $path - ABORTING."
	    continue
	}
    }
}

makeDirectory -path $srcParent
makeDirectory -path $destParent

# Set a flag/output string for determining whether we're backing up or restoring
$srcLetter = (Get-Item $srcParent).PSDrive.Name
$destLetter = (Get-Item $destParent).PSDrive.Name

if ($destLetter -eq "F" -Or $destParent -like "*Backups*") {
    $copyType = "Backup"
} elseif ($srcLetter -eq "F" -Or $srcParent -like "*Backups*") {
    $copyType = "Restore"
} else {
    Write-Host -back black -fore Red "Invalid path. Aborting."
    exit
}

$users = Get-LocalUser | ? { $_.Enabled -eq "True" -And $_.Name -notlike "default*" } | select -ExpandProperty Name

Write-Host -back black -fore green "`nUsers = $users"

foreach ($user in $users) {
    if $(!AutomateUsers) {
	$path =  gwmi Win32_userprofile | ? { $_.LocalPath -like "*$user*" } | select -ExpandProperty LocalPath
	if ($path) {
	    if (ask "`nWould you like to $copyType $user") {
		copyWrap -copyType $copyType -srcParent $srcParent -destParent $destParent -user $user
	    } else {
		Write-Host -back black -fore cyan "Skipping $user"
	    }
	} else {
	    Write-Host -back black -fore red "`n$user has no profile."
	}
    } else {
	$path =  gwmi Win32_userprofile | ? { $_.LocalPath -like "*$user*" } | select -ExpandProperty LocalPath
	if ($path) {
	    copyWrap -copyType $copyType -srcParent $srcParent -destParent $destParent -user $user
	    if ($user -eq $users[-1]) { Write-Host }
	} else {
	    Write-Host -back black -fore red "`n$user has no profile."
	}
    }
    if ($user -eq $users[-1]) { Write-Host }
}
