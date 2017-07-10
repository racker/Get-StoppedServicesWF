workflow Get-StoppedServicesWF
{
  #Get Creds
  Write-Output "Getting Azure credentials...."
  $AzureUser="AzureCred"
  $AzureCred = Get-AutomationPSCredential -Name $AzureUser
  Write-Output $AzureCred
   
  Write-Output "Logging into Azure...."
  #Login to Azure Subscription
  Login-AzureRmAccount -Credential $AzureCred
  $SubscriptionName = (Get-AzureRmSubscription).Name
  Select-AzureRmSubscription -SubscriptionName $SubscriptionName
  
  Write-Output "Getting Local credentials...."
  #Get Domain Creds to run local workflows
  $DomainUser="DomainCred"
  $DomainCred = Get-AutomationPSCredential -Name $DomainUser
  Write-Output $DomainCred
  
  #Update customer Id to your OMS workspace ID
  $CustomerID = Get-AutomationVariable -Name 'OMSWSID'
  
  #For shared key use either the primary or seconday Connected Sources client authentication key   
  $SharedKey = Get-AutomationVariable -Name 'OMSWSPK'
  
  #Get Workspace name and Resourcegroup name for OMS Search API function
  $WorkSpaceName =Get-AutomationVariable -Name 'OMSWSName'
  $ResourceGroupName = Get-AutomationVariable -Name 'OMSResourceGroup'

  #Get the Server Filter, Services List, and name of Custom OMS Log
  $ServerNameFilter = Get-AutomationVariable -Name 'ServerNameFilter' # Be sure to include Wildcards before and after if searcing for multiple VMs
  $Services = Get-AutomationVariable -Name 'ServicesList' # Should be a comma seperated list of services to check for
  $CustomOMSLog = Get-AutomationVariable -Name 'OMSLogName' # Name that the new OMS Log Type will be called (when searching add _cl to the end of it)


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