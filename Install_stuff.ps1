param (
    $sqlDatabaseName,
    $sqlServerName,
    $sqlUserName,
    $sqlPassword,
    $rootPath,
    $appUser,
    $appPassword,
    $loginMYGServer,
    $loginMYGDatabase,
    $loginMYGUser,
    $loginMYGPassword,
	$versionOfAdapter
    )																						

$sqlServerName = $sqlServerName + ".database.windows.net" #adding DNS suffix to Azure SQL Server name

#Write-Host "Creating path $rootPath"
New-Item -Path "$rootPath" -ItemType "directory" -Force
Set-Location $rootPath

function WriteLog
{
    Param ([string]$LogString)
	#$Date = "[{0:yyyyMMdd}]" -f (Get-Date)
    $LogFile = "$rootPath\LOGS_DeployToAzure.log"
    $DateTime = "[{0:MM/dd/yyyy} {0:HH:mm:ss}]" -f (Get-Date)
    $LogMessage = "$Datetime $LogString"
    Add-content $LogFile -value $LogMessage
}

WriteLog "Creating path $rootPath"

#$versionOfAdapter = 'v1.4.0.9'
$urlDownload = "https://github.com/Geotab/mygeotab-api-adapter/releases/download/"
$zipfileOfAdapter = "/MyGeotabAPIAdapter_SCD_win-x64.zip"
$zipfileOfSQL = "/SQLServer.zip"
$urlforzipfileAdapter = $urlDownload + $versionOfAdapter + $zipfileOfAdapter
$urlforzipfileSQL = $urlDownload + $versionOfAdapter + $zipfileOfSQL
$packages = $($urlforzipfileAdapter, $urlforzipfileSQL)

#$packages = $( #array of packages to download & extract to $rootPath
#    'https://github.com/Geotab/mygeotab-api-adapter/releases/download/v1.4.0.9/MyGeotabAPIAdapter_SCD_win-x64.zip',
#    'https://github.com/Geotab/mygeotab-api-adapter/releases/download/v1.4.0.9/SQLServer.zip',
#	'https://storageacctsun02.blob.core.windows.net/myazblob/TS4Adapter.ps1'
#)

Foreach ($p in $packages)
{   
    #Write-Host "Downloading $p and saving as $fileName"
    $fileName = ($p -split "/")[-1]
    Invoke-WebRequest -Uri $p -UseBasicParsing -outfile $fileName -Verbose   
    Expand-Archive $fileName -Force -Verbose -DestinationPath $rootPath
	WriteLog "Downloading $p and saving as $fileName"
}

##SQL Server Module Install:
Install-PackageProvider -Name NuGet -RequiredVersion 2.8.5.201 -Force -Verbose #is this a dep?
#Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
#Install-Module -Name Az -Scope CurrentUser -Repository PSGallery -Force -Verbose
Install-Module -Name SqlServer -Repository PSGallery -Force -Verbose -AllowClobber 
Install-Module Az.Accounts -MinimumVersion 2.2.0 -Repository PSGallery -Force -Verbose -AllowClobber #needed for MSI login

#Write-Host "Trying to connect to SQL Server: $sqlServerName"
WriteLog "Trying to connect to SQL Server: $sqlServerName"

Invoke-Sqlcmd -ServerInstance $sqlServerName `
            -Database 'master' `
            -Username $sqlUserName `
            -Password $sqlPassword `
            -Query "CREATE LOGIN [$appUser] WITH PASSWORD=N'$appPassword'" `
            -Verbose

Invoke-Sqlcmd -ServerInstance $sqlServerName `
            -Database $sqlDatabaseName `
            -Username $sqlUserName `
            -Password $sqlPassword `
            -Query "CREATE USER [$appUser] FOR LOGIN [$appUser] WITH DEFAULT_SCHEMA=[dbo]; ALTER ROLE [db_datareader] ADD MEMBER [$appUser]; ALTER ROLE [db_datawriter] ADD MEMBER [$appUser];" `
            -Verbose

Invoke-Sqlcmd -ServerInstance $sqlServerName `
            -Database $sqlDatabaseName `
            -Username $sqlUserName `
            -Password $sqlPassword `
            -InputFile "$rootPath\SQLServer\geotabadapterdb-DatabaseCreationScript.sql" `
            -Verbose `
            -IncludeSqlUserErrors

WriteLog "Excuted the SQL Server database creation scripts."

$appSettingsFile = "$rootPath\MyGeotabAPIAdapter_SCD_win-x64\appsettings.json"
$pattern = '//"Database'

#strip out JSON-invalid comment lines
$output = Get-Content $appSettingsFile | Where-Object { $_ -notmatch $pattern}
$output | Set-Content $appSettingsFile #PS didn't like reading from and writing back to the config file in the same line

#manipulate JSON config:
$json = Get-Content $appSettingsFile -Raw | ConvertFrom-Json -Verbose
$json.DatabaseSettings.DatabaseProviderType = 'SQLServer'
$json.DatabaseSettings.DatabaseConnectionString  = "Server=$sqlServerName;Database=$sqlDatabaseName;User Id=$appUser;Password=$appPassword"
$json.LoginSettings.MyGeotabServer  = "$loginMYGServer"
$json.LoginSettings.MyGeotabDatabase  = "$loginMYGDatabase"
$json.LoginSettings.MyGeotabUser  = "$loginMYGUser"
$json.LoginSettings.MyGeotabPassword  = "$loginMYGPassword"
$json | ConvertTo-Json -Depth 32 | Set-Content $appSettingsFile

WriteLog "Updated the appsettings.json file."

#create a Task Scheduler to run the Adapter automatically 
$PSFileName = "psfile_01.ps1"
New-Item -Path $rootPath -Type "file" -Name $PSFileName 
$AdapterLocation = "$rootPath\MyGeotabAPIAdapter_SCD_win-x64"

Set-Content $PSFileName '#This is the script to create a task scheduler for loading the API Adapter.'
Add-Content $PSFileName 'Import-Module ScheduledTasks'
Add-Content $PSFileName '$WorkingLocation = "' -NoNewline
Add-Content $PSFileName -Value $AdapterLocation -NoNewline
Add-Content $PSFileName '"'
Add-Content $PSFileName '$DateTime_TS = (Get-Date).AddMinutes(1)'
Add-Content $PSFileName '$action = New-ScheduledTaskAction -Execute "C:\Windows\System32\cmd.exe" -Argument "/c MyGeotabAPIAdapter.exe" -WorkingDirectory "$WorkingLocation\"'
Add-Content $PSFileName '$trigger = New-ScheduledTaskTrigger -Once -At "$DateTime_TS" -RandomDelay (New-TimeSpan -Minute 1)'
Add-Content $PSFileName '$principal = New-ScheduledTaskPrincipal -UserID "NT AUTHORITY\SYSTEM" -LogonType ServiceAccount -RunLevel Highest'
Add-Content $PSFileName '$settings = New-ScheduledTaskSettingsSet -RunOnlyIfNetworkAvailable -WakeToRun'
Add-Content $PSFileName '$task = New-ScheduledTask -Action $action -Trigger $trigger -Settings $settings -Principal $principal'
Add-Content $PSFileName 'Register-ScheduledTask "T1" -InputObject $task'

WriteLog "Created a ps file $PSFileName for a Windows Scheduled Task in the server $env:computername."
#wait 120-300 seconds (2-5 minutes) for SQL database being ready
Wait-Event -Timeout 180
Powershell.exe ".\$PSFileName"
WriteLog "A Windows Scheduled Task named T1 is successfully created in the server $env:computername."
