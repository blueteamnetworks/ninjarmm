$ApplicationId       = "Your Application ID"
$ApplicationSecret   = "Your Application Secret" | Convertto-SecureString -AsPlainText -Force
$refreshToken        = "SuperLongRefreshToken"
$TenantID         = "Your Partner Tenant ID"
$Exchangetoken = "ExchangeRefreshToken"
$apiKey                = "YourSyncroAPIToken"
$apiUri                = "https://yoursyncrosubdomain.syncromsp.com/api/v1/"

If (Get-Module -ListAvailable -Name "MsOnline") { Import-module "Msonline" } Else { install-module "MsOnline" -Force; import-module "Msonline" }
If (Get-Module -ListAvailable -Name "AzureAD") { Import-module "AzureAD" } Else { install-module "AzureAD" -Force; import-module "AzureAD" }
If (Get-Module -ListAvailable -Name "PartnerCenter") { Import-module "PartnerCenter" } Else { install-module "PartnerCenter" -Force; import-module "PartnerCenter" }
 
$credential = New-Object System.Management.Automation.PSCredential($ApplicationId, $ApplicationSecret)
$aadGraphToken = New-PartnerAccessToken -ApplicationId $ApplicationId -Credential $credential -RefreshToken $refreshToken -Scopes 'https://graph.windows.net/.default' -ServicePrincipal
$graphToken = New-PartnerAccessToken -ApplicationId $ApplicationId -Credential $credential -RefreshToken $refreshToken -Scopes 'https://graph.microsoft.com/.default'
 
Connect-MsolService -AdGraphAccessToken $aadGraphToken.AccessToken -MsGraphAccessToken $graphToken.AccessToken
$customers = Get-MsolPartnerContract
$fieldMaps = @{name='displayName';address1='streetAddress';city='city';zip='postalCode';state='state';phone='businessPhones'}
 
function compareValues{
   param([string]$o365,[string]$syncro)
 
   if ($o365 -ne $null -and $o365 -ne $syncro) {
      $return += " - $o365 is $syncro"
   }
   return $return
}

# Check for contacts in Office 365 and Syncro and if not in Syncro then add them
foreach ($customer in $customers) {
    $CustomerToken = New-PartnerAccessToken -ApplicationId $ApplicationId -Credential $credential -RefreshToken $refreshToken -Scopes 'https://graph.microsoft.com/.default' -Tenant $customer.TenantID
    $headers = @{ "Authorization" = "Bearer $($CustomerToken.AccessToken)" }
    Write-host "Collecting data for $($Customer.Name) [$($Customer.defaultdomainname)] " -ForegroundColor Green

    $query = [System.Web.HTTPUtility]::UrlEncode($($Customer.Name))
    $companySyncroID = (Invoke-RestMethod -Uri "$apiUri/customers?query=$query" -Method Get -Header @{ "Authorization" = $apiKey } -ContentType "application/json")[0].customers.id
 
    if ($companySyncroID -eq $null) {
        write-host "Client $($Customer.Name) not found SyncroMSP" -ForegroundColor Red 
    } else {
        write-host "Getting client ID# $companySyncroID for $($Customer.Name) from SyncroMSP" -ForegroundColor Green 
        $domains = Get-MsolDomain
        $allusersO365 = (Invoke-RestMethod -Uri 'https://graph.microsoft.com/beta/users?$top=999' -Headers $Headers -Method Get -ContentType "application/json").value | Where-Object {$_.mail -ne $null -and $_.assignedLicenses -ne $null}
        $Syncro = (Invoke-RestMethod -Method Get -Uri "$apiUri/contacts?customer_id=$companySyncroID" -Header @{ "Authorization" = $apiKey } -ContentType "application/json")
        $allusersSyncro = $syncro.contacts
 
        $totalPages = $Syncro.meta.total_pages
        if ($totalPages -ne 1) {
            for($i=2; $i -le $totalPages; $i++){
                $allusersSyncro += (Invoke-RestMethod -Method Get -Uri "$apiUri/contacts?customer_id=$companySyncroID&page=$i" -Header @{ "Authorization" = $apiKey } -ContentType "application/json").contacts
            }
        }
 
        ### Search for users in Syncro and compre with Office365 ####
        $UserObj = foreach ($userO365 in $allusersO365) {
            $userSyncro = $allusersSyncro | Where-Object{$_.email -like $($userO365.mail)}
            if ($userSyncro -ne $null){
#                Try {
#                    $street = $userO365.streetAddress.split(",",2)
#                    $street[1] = $street[1].trim()
#                    if ($street[1] -ne $null -and $street[1] -ne $userSyncro.address2) {$userSyncro.address2 = $street[1]; $changed += $street[1]}
#                } catch {
#                    $street[0] = $userO365.streetAddress     
#                }
                try {
                $changed = @()
                ### Check if AD field is empty, if yes - don't overwrite it in Syncro ###
                if ($userO365.displayName -ne $null -and $userO365.displayName -ne $userSyncro.name) {$userSyncro.name = $userO365.displayName; $changed += $userO365.displayName}
                

#                if ($street[0] -ne $null -and $street[0] -ne $userSyncro.address1) {$userSyncro.address1 = $street[0]; $changed += $street[0]}
#                if ($userO365.city -ne $null -and $userO365.city -ne $userSyncro.city) {$userSyncro.city = $userO365.city; $changed += $userO365.city}
#                if ($userO365.postalCode -ne $null -and $userO365.postalCode -ne $userSyncro.zip) {$userSyncro.zip = $userO365.postalCode; $changed += $userO365.postalCode}
#                if ($userO365.state -ne $null -and $userO365.state -ne $userSyncro.state) {$userSyncro.state = $userO365.state; $changed += $userO365.state}
#                if ($userO365.businessPhones[0] -ne $null -and $userO365.businessPhones[0] -ne $userSyncro.phone) {$userSyncro.phone = $userO365.businessPhones[0]; $changed += $userO365.businessPhones[0]}
#                if ($userO365.mobilePhone -ne $null -and $userO365.mobilePhone -ne $userSyncro.mobile) {$userSyncro.mobile = $userO365.mobilePhone; $changed += $userO365.mobilePhone}
                } catch {
                    Write-Output $userSyncro
                }
 
                if ($changed -ne $null) {
                    Write-Host "Contact updated for $($userSyncro.name)"
                    $editUserSyncroStatus = Invoke-RestMethod -Method PUT -Uri "$apiUri/contacts/$($userSyncro.id)" -Header @{ "Authorization" = $apiKey } -ContentType "application/json" -Body (ConvertTo-Json $userSyncro)
 
                }
 
            } else {
                #### Found new user - adding to Syncro ####
                Write-Host "$($userO365.displayname) not found in SyncroMSP - Creating...." -ForegroundColor Red
                # add new user
                #Write-Host $userO365
#                Try {
#                    $street = $userO365.streetAddress.split(",",2)
#                    $street[1] = $street[1].trim()
#                    if ($street[1] -ne $null -and $street[1] -ne $userSyncro.address2) {$userSyncro.address2 = $street[1]; $changed += $street[1]}
#                } catch {
#                    $street[0] = $userO365.streetAddress     
#                }
 
                $properties = [PSCustomObject]@{ 
                    'title'                  = $userO365.jobTitle
                    'notification_billing'   = 'false'
                    'notification_marketing' = 'true'
                }
                $newSyncroUser = [PSCustomObject]@{
                    'customer_id' = $companySyncroID
                    'name'        = $userO365.displayname
 #                   'address1'    = $street[0]
 #                   'address2'    = $street[1]
 #                   'city'        = $userO365.city
 #                   'state'       = $userO365.state
 #                   'zip'         = $userO365.postalCode
                    'email'       = $userO365.mail
                    'phone'       = $userO365.businessPhones[0]
                    'mobile'      = $userO365.mobilePhone
                    'properties'  = @($properties)
                    'opt_out'     = 'False'
                }
 
                $newUserSyncro = (Invoke-RestMethod -Method POST -Uri "$apiUri/contacts" -Header @{ "Authorization" = $apiKey } -ContentType "application/json" -Body (ConvertTo-Json $newSyncroUser))      
            }
 
        }
 
        #### Search for contact in Syncro that no longer exists in Office365 ####
        #$UserSyncroObj = foreach ($userSyncro in $allusersSyncro) {
        #    $userO365 = $allusersO365 | Where-Object{$_.mail -like $userSyncro.email}
        #    if ($userO365 -eq $null){
        #          Write-Host "$($userSyncro.name) was not found in Office365 - Deleting...." -ForegroundColor Red  
        #          $newUserSyncro = (Invoke-RestMethod -Method DELETE -Uri "$apiUri/contacts/$($userSyncro.id)" -Header @{ "Authorization" = $apiKey } -ContentType "*/*" )      
        #    }
        #}
    }
 
}