<#
.Synopsis
   Add two virtual machines to Azure subscription, deploy the provided WebPI application to the front end machine, 
   and conect it to the back end SQL Server virtual machine.
.DESCRIPTION
   This is a sample script demonstrating how to deploy a virtual machine that will host an application published on
   the Web Platform Installer catalog and will connect to a back end SQL Server.
.EXAMPLE
    Use the following to query an image name for the back end

    (Get-AzureVMImage | 
              where {($_.Label -ilike "*SQL Server*") -and ($_.PublisherName -ilike "*Microsoft*")} | 
              Sort-Object PublishedDate)[0] 
   
   Add-AzureStripedDiskSqlVm.ps1 -ServiceName mytestservice -Location "West US" -ComputerName frontend -InstanceSize Medium
.INPUTS
   none
.OUTPUTS
   none
#>
param
(
    
    # Name of the service the VMs will be deployed to. If the service exists, the VMs will be deployed ot this service, otherwise, it will be created.
    [Parameter(Mandatory = $true)]
    [String]
    $ServiceName,
    
    # The target region the VMs will be deployed to. This is used to create the affinity group if it does not exist. If the affinity group exists, but in a different region, the commandlet displays a warning.
    [Parameter(Mandatory = $true)]
    [String]
    $Location,
       
    # The host name for the SQL server.
    [Parameter(Mandatory = $true)]
    [String]
    $ComputerName,
    
    # Instance size for the SQL server. We will use 4 disks, so it has to be a minimum Medium size. The validate set checks that.
    [Parameter(Mandatory = $true)]
    [ValidateSet("Medium", "Large", "ExtraLarge", "A6", "A7")]
    [String]
    $InstanceSize)

# The script has been tested on Powershell 3.0
Set-StrictMode -Version 3

# Following modifies the Write-Verbose behavior to turn the messages on globally for this session
$VerbosePreference = "Continue"

# Check if Windows Azure Powershell is avaiable
if ((Get-Module Azure) -eq $null)
{
    throw "Windows Azure Powershell not found! Please make sure to install them from http://www.windowsazure.com/en-us/downloads/#cmd-line-tools"
}

<#
.SYNOPSIS
   Installs a WinRm certificate to the local store
.DESCRIPTION
   Gets the WinRM certificate from the Virtual Machine in the Service Name specified, and 
   installs it on the Current User's personal store.
.EXAMPLE
    Install-WinRmCertificate -ServiceName testservice -vmName testVm
.INPUTS
   None
.OUTPUTS
   Microsoft.WindowsAzure.Management.ServiceManagement.Model.OSImageContext
#>
function Install-WinRmCertificate($ServiceName, $VMName)
{
    $vm = Get-AzureVM -ServiceName $ServiceName -Name $VMName
    $winRmCertificateThumbprint = $vm.VM.DefaultWinRMCertificateThumbprint
    
    $winRmCertificate = Get-AzureCertificate -ServiceName $ServiceName -Thumbprint $winRmCertificateThumbprint -ThumbprintAlgorithm sha1
    
    $installedCert = Get-Item Cert:\CurrentUser\My\$winRmCertificateThumbprint -ErrorAction SilentlyContinue
    
    if ($installedCert -eq $null)
    {
        $certBytes = [System.Convert]::FromBase64String($winRmCertificate.Data)
        $x509Cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate
        $x509Cert.Import($certBytes)
        
        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store "Root", "LocalMachine"
        $store.Open("ReadWrite")
        $store.Add($x509Cert)
        $store.Close()
    }
}

$existingVm = Get-AzureVM -ServiceName $ServiceName -Name $ComputerName -ErrorAction SilentlyContinue
if ($existingVm -ne $null)
{
    throw "A VM with name $ComputerName exists on $ServiceName"
}

# Image name
$sqlServerImage = "fb83b3509582419d99629ce476bcb5c8__Microsoft-SQL-Server-2012SP1-Enterprise-CY13SU04-SQL2012-SP1-11.0.3350.0-Win2012"

$credential = Get-Credential

$vm = New-AzureVMConfig -Name $ComputerName -InstanceSize $InstanceSize `
          -ImageName $sqlServerImage | 
        Add-AzureProvisioningConfig -Windows -AdminUsername $credential.GetNetworkCredential().username `
          -Password $credential.GetNetworkCredential().password
          
# This example assumes the use of Medium instance size, thus hardcoding the number disks to add.
# Please see http://msdn.microsoft.com/en-us/library/windowsazure/dn197896.aspx for Azure instance sizes
$numberOfDisks = 4     
$numberOfDisksPerPool = 2
$numberOfPools = 2

# we will be striping the disks, with one copy. To illustrate this point, let's check if the disks add up.
if ($numberOfDisks -ne ($numberOfPools * $numberOfDisksPerPool))
{
    throw "The total number of disks requested in the pools cannot be different than the available disks"
}

for ($index = 0; $index -lt $numberOfDisks; $index++)
{ 
    $label = "Data disk " + $index
    $vm = $vm | Add-AzureDataDisk -CreateNew -DiskSizeInGB 10 -DiskLabel $label -LUN $index
}          

if (Test-AzureName -Service -Name $ServiceName)
{
    New-AzureVM -ServiceName $ServiceName -VMs $vm -WaitForBoot | Out-Null
    if ($?)
    {
        Write-Verbose "Created the VMs."
    }
} 
else
{
    New-AzureVM -ServiceName $ServiceName -Location $Location -VMs $vm -WaitForBoot | Out-Null
    if ($?)
    {
        Write-Verbose "Created the VMs and the cloud service $ServiceName"
    }
}


# Get the RemotePS/WinRM Uri to connect to
$winRmUri = Get-AzureWinRMUri -ServiceName $ServiceName -Name $ComputerName

Install-WinRmCertificate $ServiceName $ComputerName

# following is a generic script that stripes n disk groups of m
$setDiskStripingScript = 
{
    param ([int] $numberOfPools, [int] $numberOfDisksPerPool)
    
    Set-ExecutionPolicy -ExecutionPolicy RemoteSigned
    
    $uninitializedDisks = Get-PhysicalDisk -CanPool $True 

    $drives = @()

    for ($index = 0; $index -lt $numberOfPools; $index++)
    {         
        $poolDisks = $uninitializedDisks | Select-Object -Skip ($index * $numberOfDisksPerPool) -First $numberOfDisksPerPool 

        $poolName = "Pool" + $index
        $newPool = New-StoragePool -FriendlyName $poolName -StorageSubSystemFriendlyName "Storage Spaces*" -PhysicalDisks $poolDisks
        
        $virtDisk = $newPool | New-VirtualDisk -FriendlyName $poolName -ResiliencySettingName Simple -ProvisioningType Fixed `
        -NumberOfDataCopies 1 -NumberOfColumns $numberOfDisksPerPool -UseMaximumSize
        $initd = $virtDisk | Initialize-Disk -PassThru 
        $partition = $initd | New-Partition -AssignDriveLetter -UseMaximumSize 
        $formatted = $partition | Format-Volume -FileSystem NTFS -Confirm:$false
        $drives += $formatted.DriveLetter

        # Wait for the storage service to pick up the changes before commencing on 
        Start-Sleep -Seconds 60
    }

    # Get current drive letter.
    $currentDriveLetter = (Get-Location).Drive.Name

    # Create directories for downloading and unpacking AdventureWorkds database.
    $downloadsDirectory = "$($currentDriveLetter):\Downloads"
    $dataDirectory = "$($currentDriveLetter):\Data"

    New-Item $downloadsDirectory -Type directory -Force
    New-Item $dataDirectory -Type directory -Force

    # Link to the AdventureWorks database.
    $adventureWorksDBDownloadUri = "http://download-codeplex.sec.s-msft.com/Download/Release?ProjectName=msftdbprodsamples&DownloadId=478214&FileTime=129906742867770000&Build=20626"
    $zipFile = "$downloadsDirectory\AdventureWorks.zip"

    # Download and unpack AdventureWorks database.
    Invoke-WebRequest -Uri $adventureWorksDBDownloadUri -OutFile $zipFile

    # Unzip the downloaded file.
    $shellApp = New-Object -com shell.application
    $destination = $shellApp.namespace($dataDirectory)
    $destination.Copyhere($shellApp.namespace($zipFile).items())

    # Create database AdventureWorks.
    Invoke-Sqlcmd -Query "CREATE DATABASE AdventureWorks2012 ON (FILENAME = '$dataDirectory\AdventureWorks2012_Data.mdf'), `
    (FILENAME = '$dataDirectory\AdventureWorks2012_Log.ldf') FOR ATTACH;"

    Import-Module “sqlps” -DisableNameChecking

    # Set the path context to the local, default instance of SQL Server.
    cd SQLSERVER:\SQL\localhost\DEFAULT\Databases

    # And the database object corresponding to AdventureWorks2012.
    $db = Get-Item AdventureWorks2012

    for ($index = 0; $index -lt $numberOfPools; $index++)
    {  
        # Get letter of the drive we will create data files on
        $driveLetter = $drives[$index]

        # Create directory to hold data and log files
        $driveDataDirectory = "$($driveLetter):\Data"
        md $driveDataDirectory

        # Create a new filegroup
        $fileGroupName = "SECONDARY" + $index
        $fileGroup = New-Object -TypeName Microsoft.SqlServer.Management.SMO.Filegroup -argumentlist $db, $fileGroupName
        $fileGroup.Create()

        # Define a DataFile object on the file group and set the FileName property. 
        $dataFileName = "datafile" + $index
        $dataFile = New-Object -TypeName Microsoft.SqlServer.Management.SMO.DataFile -argumentlist $fileGroup, $dataFileName

        # Make sure to have a directory created to hold the designated data file
        $dataFile.FileName = "$driveDataDirectory\datafile$index.ndf"

        # Call the Create method to create the data file on the instance of SQL Server. 
        $dataFile.Create()

        # Define a LogFile object on the file group and set the FileName property. 
        $logFileName = "logfile" + $index
        $logFile = New-Object -TypeName Microsoft.SqlServer.Management.SMO.LogFile -argumentlist $db, $logFileName

        # Set a location for it - make sure the directory exists
        $logFile.FileName = "$driveDataDirectory\datafile$index.ldf"
        
        # Set file growth to 6%
        $logFile.GrowthType = [Microsoft.SqlServer.Management.Smo.FileGrowthType]::Percent
        $logFile.Growth = 6.0

        # Call the Create method to create the data file on the instance of SQL Server. 
        $logFile.Create()
    }        

    # Create the firewall rule for the SQL Server access
    netsh advfirewall firewall add rule name= "SQLServer" dir=in action=allow protocol=TCP localport=1433
}

# Following is a special condition for striping for this deployment, with 2 groups, 2 disks each (thus @(2, 2) parameters)"
Invoke-Command -ConnectionUri $winRmUri.ToString() -Credential $credential -ScriptBlock $setDiskStripingScript `
    -ArgumentList @($numberOfPools, $numberOfDisksPerPool)
