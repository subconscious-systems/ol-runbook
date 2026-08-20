targetScope = 'resourceGroup'

@description('Existing Azure DNS zone name.')
param dnsZoneName string

@description('Stable runner managed identity name, used only to create deterministic role assignment IDs.')
param runnerIdentityName string

@description('Runner managed identity service principal ID.')
param runnerPrincipalId string

resource dnsZone 'Microsoft.Network/dnsZones@2023-07-01-preview' existing = {
  name: dnsZoneName
}

var dnsZoneContributorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  'befefa01-2a29-4197-83a8-272ff33ce314'
)
var userAccessAdministratorRoleId = subscriptionResourceId(
  'Microsoft.Authorization/roleDefinitions',
  '18d7d88d-d35e-4fb5-a5c3-7773c20a72d9'
)

resource runnerDnsContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dnsZone.id, runnerIdentityName, dnsZoneContributorRoleId)
  scope: dnsZone
  properties: {
    principalId: runnerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: dnsZoneContributorRoleId
  }
}

resource runnerDnsUserAccess 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(dnsZone.id, runnerIdentityName, userAccessAdministratorRoleId)
  scope: dnsZone
  properties: {
    principalId: runnerPrincipalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: userAccessAdministratorRoleId
  }
}
