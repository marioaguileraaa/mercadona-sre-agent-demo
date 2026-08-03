targetScope = 'subscription'

@description('Existing ArcBox resource group. This deployment never creates or replaces the resource group.')
param arcResourceGroupName string

@description('Azure region used for the additive fleet observability resources.')
param location string = 'westeurope'

@description('Full resource ID of the existing ArcBox Log Analytics workspace.')
param workspaceResourceId string

@description('Full resource ID of the existing action group reused by both fleet alerts.')
param actionGroupResourceId string

@description('Exact existing Arc-enabled machines that make up the observed fleet.')
@minLength(2)
@maxLength(12)
param fleetMachineNames array = [
  'ArcBox-Win2K22'
  'ArcBox-Win2K25'
  'ArcBox-SQL'
  'Arcbox-Ubuntu-01'
  'Arcbox-Ubuntu-02'
]

@description('Name of the sustained CPU saturation alert.')
param cpuSaturationAlertName string = 'alert-arcbox-fleet-cpu-saturation'

@description('Name of the sustained memory pressure alert.')
param memoryPressureAlertName string = 'alert-arcbox-fleet-memory-pressure'

@description('Display name of the Azure Monitor workbook that visualises the Arc fleet.')
param workbookDisplayName string = 'ArcBox FleetOps - Azure Arc fleet observability'

@description('Sustained CPU utilisation percentage that counts as a breaching sample.')
@minValue(50)
@maxValue(99)
param cpuSaturationPercent int = 85

@description('Sustained memory used percentage that counts as a breaching sample.')
@minValue(50)
@maxValue(99)
param memoryPressurePercent int = 80

@description('Minimum number of 60 second breaching samples inside the 15 minute window before an alert fires.')
@minValue(3)
@maxValue(15)
param minimumBreachingSamples int = 8

@description('Tags applied only to resources owned by this additive extension.')
param tags object = {
  purpose: 'sre-agent-demo'
  environment: 'demo'
  dataClassification: 'synthetic'
  scenario: 'arc-fleet-observability'
}

module fleetMonitoring 'core/arc-fleet-monitoring.bicep' = {
  name: 'arc-fleet-monitoring'
  scope: resourceGroup(arcResourceGroupName)
  params: {
    location: location
    workspaceResourceId: workspaceResourceId
    actionGroupResourceId: actionGroupResourceId
    fleetMachineNames: fleetMachineNames
    cpuSaturationAlertName: cpuSaturationAlertName
    memoryPressureAlertName: memoryPressureAlertName
    workbookDisplayName: workbookDisplayName
    cpuSaturationPercent: cpuSaturationPercent
    memoryPressurePercent: memoryPressurePercent
    minimumBreachingSamples: minimumBreachingSamples
    tags: tags
  }
}

output workbookId string = fleetMonitoring.outputs.workbookId
output workbookName string = fleetMonitoring.outputs.workbookName
output cpuSaturationAlertId string = fleetMonitoring.outputs.cpuSaturationAlertId
output memoryPressureAlertId string = fleetMonitoring.outputs.memoryPressureAlertId
output fleetMachineResourceIds array = fleetMonitoring.outputs.fleetMachineResourceIds
