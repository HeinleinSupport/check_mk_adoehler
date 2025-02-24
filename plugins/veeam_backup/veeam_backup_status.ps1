# This powershell script needs to be run with the 64bit powershell
# and thus from a 64bit check_mk agent
# If a 64 bit check_mk agent is available it just needs to be renamed with
# the extension .ps1
# If only a 32bit  check_mk agent is available it needs to be relocated to a
# directory given in veeam_backup_status.bat and the .bat file needs to be
# started by the check_mk agent instead.
###
## http://blogs.technet.com/b/heyscriptingguy/archive/2006/12/04/how-can-i-expand-the-width-of-the-windows-powershell-console.aspx

$pshost = get-host
$pswindow = $pshost.ui.rawui

$newsize = $pswindow.buffersize
$newsize.height = 300
$newsize.width = 150
$pswindow.buffersize = $newsize

###
# Get Information from veeam backup and replication in cmk-friendly format
# V0.9
# Load Veeam Backup and Replication Powershell Snapin
Add-PSSnapin VeeamPSSnapIn -ErrorAction SilentlyContinue

# No real error handling in the whole script, just using this try ... catch   for totally unexpected errors.
# If any error occurs during check, a field might just remain blank

try
{
# Create new text string for backup job section. Initialize it with header
$myJobsText = "<<<veeam_jobs:sep(9)>>>`n"
# Create new text string for backup tasks section.
$myTaskText = ""

# List all planned backup AND replication jobs which are ENABLED
$myBackupJobs = Get-VBRJob | where {$_.IsScheduleEnabled -eq $true }
# to check only for Backups or Replicas: "$_.IsBackup -eq $true" "$_.IsReplica -eq $true"

# Iterate through all backup jobs
foreach ($myJob in $myBackupJobs)
{
	$myJobName = ""
	$myJobName = $myJob.Name
	$myJobName = $myJobName -replace " ","_"

	$myJobType = ""
	$myJobType = $myjob.JobType

	$myJobLastState = ""
	$myJobLastState = $myJob.GetLastState()

	$myJobLastResult = ""
	$myJobLastResult = $myJob.GetLastResult()

	$myJobLastSession = $myJob.FindLastSession()

	$myJobCreationTime = ""
	$myJobCreationTime = $myJobLastSession.CreationTime |  get-date -Format "dd.MM.yyyy HH:mm:ss"  -ErrorAction SilentlyContinue

	$myJobEndTime = ""
	$myJobEndTime = $myJobLastSession.EndTime |  get-date -Format "dd.MM.yyyy HH:mm:ss"  -ErrorAction SilentlyContinue

	$myJobsText = "$myJobsText" + "$myJobName" + "`t" + "$myJobType" + "`t" + "$myJobLastState" + "`t" + "$myJobLastResult" + "`t" + "$myJobCreationTime" + "`t" + "$myJobEndTime" + "`n"

	# Each backup job has a number of tasks which were executed (VMs which were processed)
	# Get all Tasks of the  L A S T  backup session
	# Caution: Each backup job MAY have run SEVERAL times for retries
	$myJobLastSessionTasks = $myJobLastSession | Get-VBRTaskSession  -ErrorAction SilentlyContinue

	# Iterate through all tasks in the last backup job
	$myTask = ""
	foreach ($myTask in $myJobLastSessionTasks)
	{
		$myTaskName = ""
		$myTaskName = $myTask.Name

		$myTaskText = "$myTaskText" + "<<<<" + "$myTaskName" + ">>>>" + "`n"

		$myTaskText = "$myTaskText" + "<<<"+ "veeam_client:sep(9)" +">>>" +"`n"

		$myTaskStatus = ""
		$myTaskStatus = $myTask.Status

		$myTaskText = "$myTaskText" + "Status" + "`t" + "$myTaskStatus" + "`n"

		$myTaskText = "$myTaskText" + "JobName" + "`t" + "$myJobName" + "`n"

		$myTaskTotalSize = ""
		$myTaskTotalSize = $myTask.Progress.TotalSize

		$myTaskText = "$myTaskText" + "TotalSizeByte" + "`t" + "$myTaskTotalSize" + "`n"

		$myTaskStartTime = ""
		$myTaskStartTime = $myTask.Progress.StartTime |  get-date -Format "dd.MM.yyyy HH:mm:ss"  -ErrorAction SilentlyContinue

		$myTaskText = "$myTaskText" + "StartTime" + "`t" + "$myTaskStartTime" + "`n"

		$myTaskStopTime = ""
		$myTaskStopTime = $myTask.Progress.StopTime |  get-date -Format "dd.MM.yyyy HH:mm:ss"  -ErrorAction SilentlyContinue

		$myTaskText = "$myTaskText" + "StopTime" + "`t" + "$myTaskStopTime" + "`n"

		# Result is a value of type System.TimeStamp. I'm sure there is a more elegant way of formatting the output:
		$myTaskDuration = ""
		$myTaskDuration = "" + "{0:D2}" -f $myTask.Progress.duration.Days + ":" + "{0:D2}" -f $myTask.Progress.duration.Hours + ":" + "{0:D2}" -f $myTask.Progress.duration.Minutes + ":" + "{0:D2}" -f $myTask.Progress.duration.Seconds

		$myTaskText = "$myTaskText" + "DurationDDHHMMSS" + "`t" + "$myTaskDuration" + "`n"

		$myTaskAvgSpeed = ""
		$myTaskAvgSpeed = $myTask.Progress.AvgSpeed

		$myTaskText = "$myTaskText" + "AvgSpeedBps" + "`t" + "$myTaskAvgSpeed" + "`n"

		$myTaskDisplayName = ""
		$myTaskDisplayName = $myTask.Progress.DisplayName
		$myTaskDisplayName = $myTaskDisplayName -replace "%","percent"
		$myTaskText = "$myTaskText" + "DisplayName" + "`t" + "$myTaskDisplayName" + "`n"

		# End of section <<<veeam.client>>>
		$myTaskText = "$myTaskText" + "<<<<" + ">>>>" +"`n"

	# END OF LOOP foreach ($myTask in $myJobLastSessionTasks)
	}

# END OF LOOP foreach ($myJob in $myBackupJobs)
}

# Final output
"$myJobsText" + "$myTaskText"


# END OF TRY
}

# CATCH only totally impossible catastrophic errors
catch
{
$errMsg = $_.Exception.Message
$errItem = $_.Exception.ItemName
Write-Error "Totally unexpected and unhandled error occured:`n Item: $errItem`n Error Message: $errMsg"
Break
}
