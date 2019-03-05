Param (
    [Parameter(Mandatory = $True, HelpMessage = "Template Name")]
    [string]$templateVMName,
    [parameter(Mandatory=$false, HelpMessage="Operating System")]
    [string]$os,
    [Parameter(Mandatory = $true, HelpMessage = "vCenter Server")]
    [string]$vCenterServer,
    [parameter(Mandatory=$false, HelpMessage="Copy Temp Datastore")]
    [string]$copyTempDatastore,
    [parameter(Mandatory=$false, HelpMessage="Copy Temp Cluster")]
    [string]$copyTempCluster,
    [parameter(Mandatory=$false, HelpMessage="Copy Template Name")]
    [string]$copyTempName,
    [parameter(Mandatory=$false, HelpMessage="Network Name")]
    [string]$networkName
)

$taskTab = @{}
#Use existing VM folder path script plus the one to find the path for individual VMs. May be a good idea to store the path in the datasource for quick retrieval
$copyTemplate = $true
Write-Output $("Getting credentials for " + $templateVMName)
$GuestOSCred = Get-Credential

function WaitForConnectivity ($vm, $time) {
    #Wait for the VM to become accessible after starting
    $timestart = Get-Date
    $timeend = $timestart.AddMinutes($time)
    do {
        # Validate IPv4 address
        $state = $false
        $IPv4Regex = '(?:(?:1\d\d|2[0-5][0-5]|2[0-4]\d|0?[1-9]\d|0?0?\d)\.){3}(?:1\d\d|2[0-5][0-5]|2[0-4]\d|0?[1-9]\d|0?0?\d)'
        $vmIPAddress = ([regex]::Matches((Get-VM $vm).Guest.IPAddress, $IPv4Regex)).Value
        $timenow = Get-Date
        Write-Output $("Waiting for " + $vm + " to respond...")
        Start-Sleep -Seconds 5
        if ($vmIPAddress){$state = Test-Connection $vmIPAddress -Quiet}
        $vmRunning = (Get-VM $vm).Guest.State -eq 'Running'
    }
    until (($state -eq $true -and $vmRunning -eq $true) -or $timenow -ge $timeend)
}

Write-Output $("Connecting to " + $VCenterServer)
Connect-VIServer $vCenterServer

#Get a host from the selected cluster
Write-Output $("Getting a host for the template")
$vmhosts = Get-Cluster $copyTempCluster | get-vmhost | ? {$_.ConnectionState -eq "Connected"} 
$copyTempHost = Get-VMHost $vmhosts[0].Name

#Get the folder
Write-Output $("Get the template folderf")
$folder = Get-Folder | ?{$_.Id -like $("Folder-" + (Get-Template $templateVMName).ExtensionData.Parent.Value)}

#Copy if copyTemplate true and either updateError false or no existing template
if ($copyTemplate -and (!($updateError) -or ((Get-Template | ? {$_.Name -eq $TemplateVMName}).count -eq 0))) {
    try {
        #Remove existing templates if they exist
            Write-Output $("Remove any pre-existing copies of the template")
            Get-Template | ? {$_.Name -eq $copyTempName} | % {
            Remove-Template $_.Name -DeletePermanently -Confirm:$false
            }
        }
        catch{
            Write-Output $($_)
        }

        #Create VM copy from template
        Write-Output $("Deploying the copy of " + $templateVMName)
        $taskTab[(New-VM -Name $copyTempName -Template $TemplateVMName -VMHost $copyTempHost -Datastore $copyTempDatastore -Location $folder -RunAsync -WarningAction SilentlyContinue).Id] = $copyTempName
	
        #Begin configuration after the VM clones from the template
        $runningTasks = $taskTab.Count
        while($runningTasks -gt 0){
          Get-Task | % {
            if($taskTab.ContainsKey($_.Id) -and $_.State -eq "Success"){
                $copyVM = $taskTab[$_.Id]
              
                #Continue if a copy was successfully created
                if (Get-VM $copyVM){
                    #Set Network on primary NIC for the machine
                    Write-Output $("Connecting Network Adapter 1 to Network Name: " + $NetworkName)
                    $NIC1 = Get-VM $copyVM | Get-NetworkAdapter -Name "Network adapter 1"
                    try {
                        Set-NetworkAdapter -NetworkAdapter $NIC1 -NetworkName $networkName -StartConnected:$true -Confirm:$false -ErrorAction Stop
                    }
                    catch {
                        Write-Output $($_)
                    }

                    # Start the VM. Answer any question with the default response  
                    Write-Output $("Attempting to start " + $copyVM) 
                    try {
                        if ((Get-VM $copyVM).PowerState -eq 'poweredoff') {
                            Start-VM -VM $copyVM | Get-VMQuestion | Set-VMQuestion -DefaultOption -Confirm:$false
                            Write-Output $($copyVM + " starting...")
                        }
                        else {
                            Write-Output $($copyVM + " is already powered on.") 
                        }
                    }
                    catch {
                        Write-Output $($_)
                    }

                    # Wait for the VM to become accessible after starting
                    waitForConnectivity -vm $copyVM -time 10

                    # Update VMware tools if needed
                    Write-Output $("Checking VMware Tools on " + $copyVM)

                    do {
                        $toolsStatus = (Get-VM $copyVM | Get-View).Guest.ToolsStatus	
                        Write-Output $("Tools Status: " + $toolsStatus)
                        Start-Sleep 3

                        if ($toolsStatus -eq "toolsOld") {
                            Write-Output $("Updating VMware Tools on " + $copyVM)
                            Update-Tools -VM $copyVM -NoReboot
                        }
                        else { Write-Output "No VMware Tools update required" }	
                    }
                    until ($toolsStatus -eq 'toolsOk')

                    if ($os -like '*windows*') {
                        #Create the temp folder for logs. This is a one time event.
                        Write-Output $("Creating the C:\Temp folder to store logs if it does not exist")
                        $createFolder = '$path = "C:\Temp\"; if(!(Test-Path $path)){New-Item -ItemType Directory -Force -Path $path}'
                        $output = (Invoke-VMScript -ScriptType PowerShell -VM $copyVM -ScriptText $createFolder -GuestCredential $GuestOSCred)
                        if($output){Write-Output $("Message: " + $output)}

                        #The following installs the NuGet package provider and the PSWindowsUpdate module which is used to install Windows updates. This is a one time event.
                        try{
                            Write-Output $("Installing the NuGet package provider if it is not already installed")
                            $output = (Invoke-VMScript -ScriptType PowerShell -VM $copyVM -ScriptText 'Install-PackageProvider -Name NuGet -RequiredVersion 2.8.5.201 -Force' -GuestCredential $GuestOSCred)
                            if($output){Write-Output $("Message: " + $output)}
                        }
                        catch{
                            Write-Output $($_)
                        }
                        try{
                            Write-Output $("Installing the PSWindowsUpdate Module if it is not already installed")
                            $output = (Invoke-VMScript -ScriptType PowerShell -VM $copyVM -ScriptText 'if (!(Get-Module -ListAvailable -Name PSWindowsUpdate)){Install-Module PSWindowsUpdate -SkipPublisherCheck -Force -Confirm:$false}' -GuestCredential $GuestOSCred)
                            if($output){Write-Output $("Message: " + $output)}
                        }
                        catch{
                            Write-Output $($_)
                        }

                        #The following is the cmdlet that will invoke the Get-WUInstall inside the GuestVM to install all available Windows   
                        #updates; optionally results can be exported to a log file to see the patches installed and related results.                    
                        Write-Output $("Running PSWindowsUpdate script")
                        try{
                            Write-Output $("Executing the update script: ipmo PSWindowsUpdate; Get-WUInstall â€“AcceptAll â€“AutoReboot -Download -Install -Verbose | Out-File C:\Temp\PSWindowsUpdate.log -Append")
                            $output = (Invoke-VMScript -ScriptType PowerShell -VM $copyVM -ScriptText "ipmo PSWindowsUpdate; Get-WUInstall â€“AcceptAll â€“AutoReboot -Download -Install -Verbose | Out-File C:\Temp\PSWindowsUpdate.log -Append" -GuestCredential $GuestOSCred)
                            if($output){Write-Output $("Message: " + $output)}
                        }
                        catch{
                            Write-Output $($_)
                        }
                        # Wait for the VM to become accessible after updating
                        waitForConnectivity -vm $copyVM -time 45
                    }
                    elseif ($os -like '*linux*') {
                        #Connect and yum update 
                        try {
                            $vmIP = ((Get-VM $copyVM).Guest.IPAddress)[0]
                            Write-Output $("Executing subscription-manager refresh;yum clean all")
                            $UpdateLog = Invoke-NaSsh -Name $vmIP -Credential $GuestOSCred -Command "subscription-manager refresh;yum clean all" -ErrorAction Stop
                            Write-Output $("Update status: $UpdateLog")
                        }
                        catch {
                            Write-Output $($_)
                        }
                         try {
                            Write-Output $("Executing yum --security update -y;yum -y update;reboot")
                            $UpdateLog = Invoke-NaSsh -Name $vmIP -Credential $GuestOSCred -Command "yum --security update -y;yum -y update;reboot" -ErrorAction Stop
                            Write-Output $("Update status: $UpdateLog")
                            Write-Output $("The Linux VM has been copied from the template and is ready for updates.")
                        }
                        catch {
                            Write-Output $($_)
                        }
                    }
                }

                else{
                    Write-Output $("The copied VM was not found. Please correct the issue and run the workflow again.")
                }
              $taskTab.Remove($_.Id)
              $runningTasks--
            }
            elseif($taskTab.ContainsKey($_.Id) -and $_.State -eq "Error"){
              $taskTab.Remove($_.Id)
              $runningTasks--
            }
          }
        Start-Sleep -Seconds 15
        }
}
else{
    Write-Output $("The copied VM was not found. Please correct the issue and run the workflow again.")
}

#Disconnect from VI server
Write-Output $("Disconnect-VIServer -Server " + $VCenterServer + " -Confirm: " + $False)
Disconnect-VIServer -Server $VCenterServer -Confirm:$False
