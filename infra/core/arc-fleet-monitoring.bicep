targetScope = 'resourceGroup'

@description('Azure region used for the additive fleet observability resources.')
param location string

@description('Full resource ID of the existing ArcBox Log Analytics workspace.')
param workspaceResourceId string

@description('Full resource ID of the existing action group reused by both fleet alerts.')
param actionGroupResourceId string

@description('Exact existing Arc-enabled machines that make up the observed fleet.')
@minLength(2)
@maxLength(12)
param fleetMachineNames array

@description('Name of the sustained CPU saturation alert.')
param cpuSaturationAlertName string

@description('Name of the sustained memory pressure alert.')
param memoryPressureAlertName string

@description('Display name of the Azure Monitor workbook that visualises the Arc fleet.')
param workbookDisplayName string

@description('Sustained CPU utilisation percentage that counts as a breaching sample.')
@minValue(50)
@maxValue(99)
param cpuSaturationPercent int

@description('Sustained memory used percentage that counts as a breaching sample.')
@minValue(50)
@maxValue(99)
param memoryPressurePercent int

@description('Minimum number of 60 second breaching samples inside the 15 minute window before an alert fires.')
@minValue(3)
@maxValue(15)
param minimumBreachingSamples int

@description('Tags applied only to resources owned by this additive extension.')
param tags object

var fleetMachineResourceIds = [
  for machineName in fleetMachineNames: toLower(resourceId('Microsoft.HybridCompute/machines', machineName))
]
var fleetMachineResourceIdsJson = string(fleetMachineResourceIds)

var cpuSaturationQuery = format('''
let FleetResourceIds = dynamic({0});
let SaturationPercent = todouble({1});
let MinimumBreachingSamples = {2};
InsightsMetrics
| where TimeGenerated >= ago(15m)
| where set_has_element(FleetResourceIds, tolower(_ResourceId))
| where Namespace == "Processor" and Name == "UtilizationPercentage"
| summarize
    Samples = count(),
    BreachingSamples = countif(Val >= SaturationPercent),
    AverageCpuPercent = round(avg(Val), 1),
    MaximumCpuPercent = round(max(Val), 1)
    by ResourceId = tolower(_ResourceId)
| where BreachingSamples >= MinimumBreachingSamples
| extend Machine = tostring(split(ResourceId, "/")[-1])
| project Machine, ResourceId, Samples, BreachingSamples, AverageCpuPercent, MaximumCpuPercent
''', fleetMachineResourceIdsJson, string(cpuSaturationPercent), string(minimumBreachingSamples))

var memoryPressureQuery = format('''
let FleetResourceIds = dynamic({0});
let PressurePercent = todouble({1});
let MinimumBreachingSamples = {2};
InsightsMetrics
| where TimeGenerated >= ago(15m)
| where set_has_element(FleetResourceIds, tolower(_ResourceId))
| where Namespace == "Memory" and Name == "AvailableMB"
| extend TotalMemoryMb = todouble(todynamic(Tags)["vm.azm.ms/memorySizeMB"])
| where TotalMemoryMb > 0
| extend MemoryUsedPercent = 100.0 * (TotalMemoryMb - Val) / TotalMemoryMb
| summarize
    Samples = count(),
    BreachingSamples = countif(MemoryUsedPercent >= PressurePercent),
    AverageMemoryUsedPercent = round(avg(MemoryUsedPercent), 1),
    MaximumMemoryUsedPercent = round(max(MemoryUsedPercent), 1),
    MinimumAvailableMb = round(min(Val), 0)
    by ResourceId = tolower(_ResourceId)
| where BreachingSamples >= MinimumBreachingSamples
| extend Machine = tostring(split(ResourceId, "/")[-1])
| project Machine, ResourceId, Samples, BreachingSamples, AverageMemoryUsedPercent, MaximumMemoryUsedPercent, MinimumAvailableMb
''', fleetMachineResourceIdsJson, string(memoryPressurePercent), string(minimumBreachingSamples))

var workbookSerializedData = replace(
  replace(
    loadTextContent('../workbooks/arc-fleet-observability.workbook.json'),
    '__WORKSPACE_RESOURCE_ID__',
    workspaceResourceId
  ),
  '__SUBSCRIPTION_RESOURCE_ID__',
  '/subscriptions/${subscription().subscriptionId}'
)

resource fleetObservabilityWorkbook 'Microsoft.Insights/workbooks@2023-06-01' = {
  name: guid(resourceGroup().id, 'arcbox-fleet-observability')
  location: location
  kind: 'shared'
  tags: tags
  properties: {
    displayName: workbookDisplayName
    description: 'Fictional technical SRE demo. Read-only visualisation of the Arc-enabled fleet: inventory, connectivity, extension posture, telemetry freshness, CPU, memory, disk, change tracking and alerts.'
    serializedData: workbookSerializedData
    version: '1.0'
    sourceId: workspaceResourceId
    category: 'workbook'
  }
}

resource cpuSaturationAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: cpuSaturationAlertName
  location: location
  kind: 'LogAlert'
  tags: tags
  properties: {
    displayName: 'ArcBox FleetOps sustained CPU saturation on an Arc-enabled server'
    description: 'Sev2 demo alert. Fires when an Arc-enabled server reports at least ${minimumBreachingSamples} samples at or above ${cpuSaturationPercent}% processor utilisation inside a 15 minute window. The observed 7 day baseline never produced a firing window.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [
      workspaceResourceId
    ]
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    resolveConfiguration: {
      autoResolved: true
      timeToResolve: 'PT15M'
    }
    checkWorkspaceAlertsStorageConfigured: false
    skipQueryValidation: false
    criteria: {
      allOf: [
        {
          query: cpuSaturationQuery
          timeAggregation: 'Count'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupResourceId
      ]
      customProperties: {
        dataClassification: 'synthetic'
        demoSynthetic: 'true'
        scenario: 'arc-fleet-observability'
        signal: 'cpu-saturation'
        thresholdPercent: '${cpuSaturationPercent}'
        minimumBreachingSamples: '${minimumBreachingSamples}'
        runbook: 'docs/runbooks/arc-fleet-saturacion-recursos.md'
      }
    }
  }
}

resource memoryPressureAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: memoryPressureAlertName
  location: location
  kind: 'LogAlert'
  tags: tags
  properties: {
    displayName: 'ArcBox FleetOps sustained memory pressure on an Arc-enabled server'
    description: 'Sev2 demo alert. Fires when an Arc-enabled server reports at least ${minimumBreachingSamples} samples at or above ${memoryPressurePercent}% memory used inside a 15 minute window. Memory used is derived from InsightsMetrics AvailableMB and the reported total memory tag.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT15M'
    scopes: [
      workspaceResourceId
    ]
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    resolveConfiguration: {
      autoResolved: true
      timeToResolve: 'PT15M'
    }
    checkWorkspaceAlertsStorageConfigured: false
    skipQueryValidation: false
    criteria: {
      allOf: [
        {
          query: memoryPressureQuery
          timeAggregation: 'Count'
          operator: 'GreaterThanOrEqual'
          threshold: 1
          failingPeriods: {
            numberOfEvaluationPeriods: 1
            minFailingPeriodsToAlert: 1
          }
        }
      ]
    }
    actions: {
      actionGroups: [
        actionGroupResourceId
      ]
      customProperties: {
        dataClassification: 'synthetic'
        demoSynthetic: 'true'
        scenario: 'arc-fleet-observability'
        signal: 'memory-pressure'
        thresholdPercent: '${memoryPressurePercent}'
        minimumBreachingSamples: '${minimumBreachingSamples}'
        runbook: 'docs/runbooks/arc-fleet-saturacion-recursos.md'
      }
    }
  }
}

output workbookId string = fleetObservabilityWorkbook.id
output workbookName string = fleetObservabilityWorkbook.name
output cpuSaturationAlertId string = cpuSaturationAlert.id
output memoryPressureAlertId string = memoryPressureAlert.id
output fleetMachineResourceIds array = fleetMachineResourceIds
