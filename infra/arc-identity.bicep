targetScope = 'subscription'

@description('Existing ArcBox resource group. This deployment never creates or replaces the resource group.')
param arcResourceGroupName string

@description('Azure region of the existing Arc-enabled machines and the dedicated DCR.')
param location string = 'westeurope'

@description('Full resource ID of the existing ArcBox Log Analytics workspace.')
param workspaceResourceId string

@description('Full resource ID of the existing action group reused by both alerts.')
param actionGroupResourceId string

@description('Exact existing Windows Arc machines associated with the dedicated DCR.')
@minLength(2)
@maxLength(2)
param targetMachineNames array = [
  'ArcBox-Win2K22'
  'ArcBox-Win2K25'
]

@description('Name of the additive identity-operations data collection rule.')
param dataCollectionRuleName string = 'dcr-arcbox-identity-ops'

@description('Name used for the new DCR association on each target machine.')
param dataCollectionRuleAssociationName string = 'assoc-arcbox-identity-ops'

@description('Name of the synthetic AD FS token-failure burst alert.')
param tokenFailureAlertName string = 'alert-arcbox-identity-token-failure-burst'

@description('Name of the Arc heartbeat and telemetry freshness alert.')
param dataFreshnessAlertName string = 'alert-arcbox-identity-data-freshness'

@description('Tags applied only to resources owned by this additive extension.')
param tags object = {
  purpose: 'sre-agent-demo'
  environment: 'demo'
  dataClassification: 'synthetic'
  scenario: 'synthetic-identity-arc'
}

module identityMonitoring 'core/arc-identity-monitoring.bicep' = {
  name: 'arc-identity-monitoring'
  scope: resourceGroup(arcResourceGroupName)
  params: {
    location: location
    workspaceResourceId: workspaceResourceId
    actionGroupResourceId: actionGroupResourceId
    targetMachineNames: targetMachineNames
    dataCollectionRuleName: dataCollectionRuleName
    dataCollectionRuleAssociationName: dataCollectionRuleAssociationName
    tokenFailureAlertName: tokenFailureAlertName
    dataFreshnessAlertName: dataFreshnessAlertName
    tags: tags
  }
}

output dataCollectionRuleId string = identityMonitoring.outputs.dataCollectionRuleId
output dataCollectionRuleAssociationIds array = identityMonitoring.outputs.dataCollectionRuleAssociationIds
output tokenFailureAlertId string = identityMonitoring.outputs.tokenFailureAlertId
output dataFreshnessAlertId string = identityMonitoring.outputs.dataFreshnessAlertId
output targetMachineResourceIds array = identityMonitoring.outputs.targetMachineResourceIds
