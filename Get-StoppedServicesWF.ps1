<#
    .SYNOPSIS
        This Azure Automation runbook queries an ARM subscription for a list of VMs and then queries the VMs for a provided list of Windows Services.
        It will then create a custom Log type and log the results within OMS.  

    .DESCRIPTION
        The runbook implements a solution for monitoring the status of user defined critical Windows services on Azure ARM VMs. 
        The administrator will need to setup the following Variables within the Azure Automation Account: 

        OMSWSID          : The OMS Workspace ID 
        OMSWSPK          : The OMS Workspace Primary Key
        OMSWSName        : The OMS Workspace Name
        OMSResourceGroup : The Resource Group of the linked OMS workspace
        ServerNameFilter : The server name filter. Can be an exact match or you can include wildcards like "*PartialServerName*"
        ServicesList     : Comma seperated list of Windows Service names to check the status of.
        OMSLogName       : Name of the custom OMS Log type where you'd like the Runbook to post its results


        This is a PowerShell Workflow runbook.

        This runbook requires the "Azure", "AzureRM.Resources", "AzureRM.OperationalInsights", "AzureRM.Compute", modules to be loaded in the Azure Automation account.

        This runbook requires the use of the Azure Hybrid Runbook Worker in order to run. Please ensure you've installed and configured one 
        in your enviornment prior to running. The Hybrid Worker may not be needed in all instances, but it was tested using it. 

    .PARAMETER AzureCredentialName
        The name of the PowerShell credential asset in the Automation account that contains username and password
        for the account used to connect to target Azure subscription. This user must be configured as co-administrator and owner
        of the subscription for best functionality. 

        For for details on credential configuration, see:
        http://azure.microsoft.com/blog/2014/08/27/azure-automation-authenticating-to-azure-using-azure-active-directory/

    .PARAMETER DomainCredentialName
        The name of the PowerShell credential asset in the Automation account that contains username and password
        for the account used to connect to target VMs. This user must be configured to allow the user to query a VM 
        using remote powershell commands. 
    
    .PARAMETER CustomerID
        The ID of Azure OMS Workspace which the automation account is tied to.
    
    .PARAMETER SharedKey
        The primary Key for the OMS Workspace

    .PARAMETER WorkSpaceName
        The name of the OMS workspace. 

    .PARAMETER ResourceGroupName
        The resource group name within which the OMS Workspace is configured. 

    .PARAMETER ServerNameFilter
        The Name filter which the workflow will use to gather the requested servers from the ARM Subscription. 

    .PARAMETER Services
        A comma seperated list of services to check the health of. Please prvide the Service Name and not the Display Name. 

    .PARAMETER CustomOMSLog
        The name of the customer OMS Log type for the script to create the events. 

    .EXAMPLE
    
    .INPUTS
        None.

    .OUTPUTS
        Log of results to the custom OMS Log Type defined by the user. 
#>
workflow Get-StoppedServicesWF
{
  [cmdletbinding()]
  Param(
    [parameter(Mandatory=$false)]
    [String] $AzureCredentialName,
    [parameter(Mandatory=$false)]
    [String] $DomainCredentialName,
    [parameter(Mandatory=$false)]
    [String] $CustomerID,
    [parameter(Mandatory=$false)]
    [String] $SharedKey,
    [parameter(Mandatory=$false)]
    [String] $WorkSpaceName,
    [parameter(Mandatory=$false)]
    [String] $ResourceGroupName,
    [parameter(Mandatory=$false)]
    [String] $ServerNameFilter,
    [parameter(Mandatory=$false)]
    [System.Collections.ArrayList] $Services,
    [parameter(Mandatory=$false)]
    [String] $CustomOMSLog
  )

  # Get Creds
  Write-Output "Getting Azure credentials...."
  if (!$AzureCredentialName)
  { 
    Write-Output "Azure Credential wasn't provided as a parameter, setting the value to AzureCred"
    $AzureCredentialName = "AzureCred" 
  }
  else
  {
    Write-Output "Azure Credential Name was provided as a parameter."
    Write-Output "Azure Credential Name: "$AzureCredentialName    
  }
  $AzureCred = Get-AutomationPSCredential -Name $AzureUser
  Write-Output $AzureCred
  
  # Login to Azure Subscription
  Write-Output "Logging into Azure...."
  Login-AzureRmAccount -Credential $AzureCred

  # Get Subscription Name and Select the Subscription to work under
  $SubscriptionName = (Get-AzureRmSubscription).Name
  Select-AzureRmSubscription -SubscriptionName $SubscriptionName

  #Get Domain Creds to run local workflows
  Write-Output "Getting Domain credentials...."
  if (!$DomainCredentialName)
  {
    Write-Output "Domain Credential Name wasn't provided as a parameter, setting the value to DomainCred"
    $DomainCredentialName = "DomainCred"
  }
  else
  {
    Write-Output "Domain Credential Name was provided as a parameter."
    Write-Output "Domain Credential Name: "$DomainCredentialName
  }
  $DomainCred = Get-AutomationPSCredential -Name $DomainCredentialName
  Write-Output $DomainCred
  
  #Update customer Id to your OMS workspace ID
  if (!$CustomerID)
  {
    Write-Output "CustomerID wasn't provided as a parameter, getting the value from the Automation Account variables"
    $CustomerID = Get-AutomationVariable -Name 'OMSWSID'
    Write-Output "CustomerID: " $CustomerID
  }
  else
  {
    Write-Output "CustomerID provided as a parameter"
    Write-Output "CustomerID: " $CustomerID
  }
  
  #For shared key use either the primary or seconday Connected Sources client authentication key
  if (!$SharedKey)
  { 
    Write-Output "SharedKey wasn't provided as a parameter, getting the value from the Automation Account variables"  
    $SharedKey = Get-AutomationVariable -Name 'OMSWSPK'
    Write-Output "SharedKey: " $SharedKey
  }
  else
  {
     Write-Output "SharedKey provided as a paramter"
     Write-Output "SharedKey: " $SharedKey 
  }
  
  #Get Workspace name and Resourcegroup name for OMS Search API function
  if(!$WorkSpaceName)
  {
    Write-Output "WorkSpaceName wasn't provided as a parameter, getting the value from the Automation Account variables"
    $WorkSpaceName =Get-AutomationVariable -Name 'OMSWSName'
    Write-Output "WorkSpaceName: " $WorkSpaceName
  }
  else
  {
    Write-Output "WorkSpaceName provided as a paramter"
    Write-Output "WorkSpaceName: " $WorkSpaceName 
  }

  if (!$ResourceGroupName)
  {
    Write-Output "ResourceGroupName wasn't provided as a parameter, getting the value from the Automation Account variables"
    $ResourceGroupName = Get-AutomationVariable -Name 'OMSResourceGroup'
    Write-Output "ResourceGroupName: " $ResourceGroupName
  }
  else 
  {
    Write-Output "ResourceGroupName provided as a paramter"
    Write-Output "ResourceGroupName: " $ResourceGroupName 
  }

  #Get the Server Filter, Services List, and name of Custom OMS Log
  if (!$ServerNameFilter)
  {
    Write-Output "ServerNameFilter wasn't provided as a parameter, getting the value from the Automation Account variables"
    $ServerNameFilter = Get-AutomationVariable -Name 'ServerNameFilter' # Be sure to include Wildcards before and after if searcing for multiple VMs
    Write-Output "ServerNameFilter: " $ServerNameFilter
  }
  else
  {
    Write-Output "ServerNameFilter provided as a paramter"
    Write-Output "ServerNameFilter: " $ServerNameFilter 
  }
  
  if(!$Services)
  {
    Write-Output "Services wasn't provided as a parameter, getting the value from the Automation Account variables"
    $Services = Get-AutomationVariable -Name 'ServicesList' # Should be a comma seperated list of services to check for
    Write-Output "Services: " $Services
  }
  else
  {
    Write-Output "Services provided as a paramter"
    Write-Output "Services: " $Services 
  }
  
  if(!$CustomOMSLog)
  {
    Write-Output "CustomOMSLog wasn't provided as a parameter, getting the value from the Automation Account variables"
    $CustomOMSLog = Get-AutomationVariable -Name 'OMSLogName' # Name that the new OMS Log Type will be called (when searching add _cl to the end of it)
    Write-Output "CustomOMSLog: " $CustomOMSLog
  }
  else
  {
    Write-Output "CustomOMSLog provided as a paramter"
    Write-Output "CustomOMSLog: " $CustomOMSLog 
  }

  #Get all VMs
  $VMs = Get-AzureRmVM -Status
  
  #$OMSComputers
  $Servers = $VMs | Where-Object -FilterScript { $_.Name -like $ServerNameFilter } 
  
  Write-Output "Servers"
  Write-Output $Servers.Name
  
  #Define custom for API
  $logtype = $CustomOMSLog
  $Timestampfield = Get-Date
 
     
  ForEach -Parallel ($Computer in $Servers)
  {
    InlineScript {
      $Array = @()
      $ComputerName=$Using:Computer.Name
      $MonitoredServices = $Using:Services
      Write-Output "Getting services on $ComputerName..."

      $Svcs = Invoke-Command -ScriptBlock {
        $Services = foreach ( $arg in $args ) { Get-Service | Where-Object -FilterScript { $_.Name -eq $arg } } 
        if ($Services)
        {
          $Services
        }
        elseif (!$Services)
        {
          $null
        }
      } -ArgumentList $MonitoredServices -Credential $Using:DomainCred -ErrorAction Continue -UseSSL -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck -SkipRevocationCheck) -Port 5986 -ComputerName $ComputerName
      
      if ($Svcs)
      {
        Foreach ($Svc in $Svcs) 
        {
          #Format OMS schmea
          $sx = New-Object PSObject ([ordered]@{
            Computer=$ComputerName
            PowerState=$Using:Computer.PowerState
            SvcDisplay=$Svc.DisplayName
            SvcName=$Svc.Name
            SvcState=$Svc.Status
          })
          $array += $sx 
        }
      }
      elseif (!$Svcs)
      {
        Foreach ($Svc in $MonitoredServices) 
        {
          #Format OMS schmea
          $sx = New-Object PSObject ([ordered]@{
            Computer=$ComputerName
            PowerState=$Using:Computer.PowerState
            SvcDisplay=$Svc
            SvcName=$Svc
            SvcState="Service Not Found"         
          })
          $array += $sx 
        }
      }
      # Send the Info to OMS
      $jsonTable = ConvertTo-Json -InputObject $array 
      $jsonTable
      Send-OMSAPIIngestionFile -customerId $Using:CustomerID -sharedKey $Using:SharedKey -body $jsonTable -logType $Using:logtype -TimeStampField $Using:Timestampfield
    }
  }
}