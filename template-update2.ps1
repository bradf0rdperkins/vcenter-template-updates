Param (
    [Parameter(Mandatory = $True, HelpMessage="Template Name")]
    [string]$templateVMName,
    [Parameter(Mandatory = $true, HelpMessage="vCenter Server")]
    [string]$vCenterServer,
    [parameter(Mandatory=$false, HelpMessage="Copy Template Name")]
    [string]$copyTempName,
    [parameter(Mandatory=$false, HelpMessage="Old/Archive Template Name")]
    [string]$oldTemplateName
)

function WaitForConnectivity ($vm, $time) {
    #Wait for the VM to become accessible after starting
    $timestart = Get-Date
    $timeend = $timestart.AddMinutes($time)
    do {
        # Validate IPv4 address
        $IPv4Regex = '(?:(?:1\d\d|2[0-5][0-5]|2[0-4]\d|0?[1-9]\d|0?0?\d)\.){3}(?:1\d\d|2[0-5][0-5]|2[0-4]\d|0?[1-9]\d|0?0?\d)'
        $vmIPAddress = ([regex]::Matches((Get-VM $vm).Guest.IPAddress, $IPv4Regex)).Value
        $timenow = Get-Date
        Write-Output $("Waiting for " + $copyTempName + " to respond...")
        Start-Sleep -Seconds 1
        $state = Test-Connection $vmIPAddress -Quiet
    }
    until ($state -eq $true -or $timenow -ge $timeend)
}


Write-Output $("Connecting to " + $VCenterServer)
Connect-WfaVIServer -ViCenterIp $vCenterServer

$copyTemplate = $true
$date = (Get-Date).ToString("MM-dd-yy")
$oldTempName = $($oldTemplateName)

# Shut down the VM and convert it back to a template  
Write-Output $("Shutting down " + $copyTempName + " and converting it back to a template")
try {
    if ((Get-VM $copyTempName).PowerState -eq 'PoweredOn'){
        Shutdown-VMGuest -VM $copyTempName -Confirm:$false -ErrorAction Stop
    }
    else {
        Write-Output $('VM was already powered down')
    }
}
catch {
    Write-Output $($_)
}

do {
    Write-Output $("Waiting for " + $copyTempName + " to shut down...") 
    Start-Sleep -Seconds 10	
}
until (Get-VM -Name $copyTempName | Where-Object { $_.powerstate -eq "PoweredOff" })

try {
    Set-VM -VM $copyTempName -ToTemplate -Confirm:$false
}
catch {
    Write-Output $($_)
}
Write-Output $("Finished updating " + $copyTempName)

try {
    #Remove existing templates if they exist
    Get-Template | ? {$_.Name -like $($TemplateVMName + "-lastmonth*")} | % {
    Remove-Template $_.Name -DeletePermanently -Confirm:$false
    }
}
    catch{
        Write-Output $($_)
    }

#Replace the old template with the updated one
Set-Template -Template $TemplateVMName -Name $oldTempName
Write-Output $("Renaming " + $TemplateVMName + " to " + $oldTempName)
Set-Template -Template $copyTempName -Name $TemplateVMName
Write-Output $("Renaming " + $copyTempName + " to " + $TemplateVMName)
Write-Output $("Script completed " + $(Get-Date))

#Disconnect from VI server
Write-Output $("Disconnect-VIServer -Server " + $vCenterServer + " -Confirm: " + $False)
Disconnect-VIServer -Server $vCenterServer -Confirm:$False
