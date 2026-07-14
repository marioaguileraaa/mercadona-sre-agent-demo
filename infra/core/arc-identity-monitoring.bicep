targetScope = 'resourceGroup'

@description('Azure region of the existing Arc-enabled machines and the dedicated DCR.')
param location string

@description('Full resource ID of the existing ArcBox Log Analytics workspace.')
param workspaceResourceId string

@description('Full resource ID of the existing action group reused by both alerts.')
param actionGroupResourceId string

@description('Exact existing Windows Arc machines associated with the dedicated DCR.')
@minLength(2)
@maxLength(2)
param targetMachineNames array

@description('Name of the additive identity-operations data collection rule.')
param dataCollectionRuleName string

@description('Name used for the new DCR association on each target machine.')
param dataCollectionRuleAssociationName string

@description('Name of the synthetic AD FS token-failure burst alert.')
param tokenFailureAlertName string

@description('Name of the Arc heartbeat and telemetry freshness alert.')
param dataFreshnessAlertName string

@description('Tags applied only to resources owned by this additive extension.')
param tags object

var logAnalyticsDestinationName = 'arcboxIdentityOpsLaw'
var targetMachineResourceIds = [
  for machineName in targetMachineNames: toLower(resourceId('Microsoft.HybridCompute/machines', machineName))
]
var targetMachineResourceIdsJson = string(targetMachineResourceIds)
var tokenFailureQuery = format('''
let TargetResourceIds = dynamic({0});
Event
| where TimeGenerated >= ago(5m)
| where set_has_element(TargetResourceIds, tolower(_ResourceId))
| where EventLog == "Application"
| where Source == "Mercadona.IdentityOps" and EventID == 4101
| where RenderedDescription contains '"demoSynthetic":true'
| project TimeGenerated, _ResourceId
''', targetMachineResourceIdsJson)
var dataFreshnessQuery = format('''
let TargetResourceIds = dynamic({0});
let CurrentUtc = now();
let CurrentMadrid = datetime_utc_to_local(CurrentUtc, "Europe/Madrid");
let MadridMinuteOfDay = datetime_part("Hour", CurrentMadrid) * 60 + datetime_part("Minute", CurrentMadrid);
let IsExpectedOperatingWindow = MadridMinuteOfDay >= 500 and datetime_part("Hour", CurrentUtc) < 18;
let ExpectedResources =
  print ResourceIds=TargetResourceIds
  | mv-expand ResourceId=ResourceIds to typeof(string)
  | project ResourceId=tolower(ResourceId);
let ExpectedSignals =
  ExpectedResources
  | extend JoinKey=1
  | join kind=inner (
      datatable(Signal:string) ["Heartbeat", "InsightsMetrics"]
      | extend JoinKey=1
    ) on JoinKey
  | project ResourceId, Signal;
let LatestSignals =
  union
    (Heartbeat
      | where TimeGenerated >= ago(20m)
      | where set_has_element(TargetResourceIds, tolower(_ResourceId))
      | project TimeGenerated, ResourceId=tolower(_ResourceId), Signal="Heartbeat"),
    (InsightsMetrics
      | where TimeGenerated >= ago(20m)
      | where set_has_element(TargetResourceIds, tolower(_ResourceId))
      | where Namespace == "Processor" and Name == "UtilizationPercentage"
      | project TimeGenerated, ResourceId=tolower(_ResourceId), Signal="InsightsMetrics")
  | summarize LastSeen=max(TimeGenerated) by ResourceId, Signal;
ExpectedSignals
| join kind=leftouter LatestSignals on ResourceId, Signal
| where IsExpectedOperatingWindow
| where isnull(LastSeen) or LastSeen < ago(10m)
| project ResourceId, Signal
''', targetMachineResourceIdsJson)

resource targetMachines 'Microsoft.HybridCompute/machines@2025-01-13' existing = [
  for machineName in targetMachineNames: {
    name: machineName
  }
]

resource identityOpsDcr 'Microsoft.Insights/dataCollectionRules@2024-03-11' = {
  name: dataCollectionRuleName
  location: location
  kind: 'Windows'
  tags: tags
  properties: {
    description: 'Additive events-only Arc identity telemetry. Performance remains in the existing VM Insights DCR and InsightsMetrics.'
    dataSources: {
      windowsEventLogs: [
        {
          name: 'identityOpsAndHostEvents'
          streams: [
            'Microsoft-Event'
          ]
          xPathQueries: [
            'Application!*[System[Provider[@Name=\'Mercadona.IdentityOps\'] and (EventID=4101 or EventID=4102)]]'
            'System!*[System[(Level=1 or Level=2 or Level=3)]]'
            'Application!*[System[(Level=1 or Level=2 or Level=3) and Provider[@Name!=\'Mercadona.IdentityOps\']]]'
          ]
        }
      ]
    }
    destinations: {
      logAnalytics: [
        {
          name: logAnalyticsDestinationName
          workspaceResourceId: workspaceResourceId
        }
      ]
    }
    dataFlows: [
      {
        streams: [
          'Microsoft-Event'
        ]
        destinations: [
          logAnalyticsDestinationName
        ]
      }
    ]
  }
}

resource identityOpsAssociations 'Microsoft.Insights/dataCollectionRuleAssociations@2024-03-11' = [
  for (machineName, index) in targetMachineNames: {
    scope: targetMachines[index]
    name: dataCollectionRuleAssociationName
    properties: {
      dataCollectionRuleId: identityOpsDcr.id
      description: 'Additive identity-operations DCR association for ${machineName}; existing associations remain untouched.'
    }
  }
]

resource tokenFailureAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: tokenFailureAlertName
  location: location
  kind: 'LogAlert'
  tags: tags
  properties: {
    displayName: 'ArcBox IdentityOps synthetic AD FS token-failure burst'
    description: 'Sev2 demo alert. Counts only events marked demoSynthetic=true from Mercadona.IdentityOps on the two target Arc machines.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    scopes: [
      workspaceResourceId
    ]
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    autoMitigate: true
    resolveConfiguration: {
      autoResolved: true
      timeToResolve: 'PT10M'
    }
    checkWorkspaceAlertsStorageConfigured: false
    skipQueryValidation: false
    criteria: {
      allOf: [
        {
          query: tokenFailureQuery
          timeAggregation: 'Count'
          operator: 'GreaterThanOrEqual'
          threshold: 8
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
        scenario: 'identity-operations'
      }
    }
  }
}

resource dataFreshnessAlert 'Microsoft.Insights/scheduledQueryRules@2023-12-01' = {
  name: dataFreshnessAlertName
  location: location
  kind: 'LogAlert'
  tags: tags
  properties: {
    displayName: 'ArcBox IdentityOps heartbeat or data freshness loss'
    description: 'Sev2 alert when Heartbeat or existing VM Insights data in InsightsMetrics is stale during the expected ArcBox operating window: 08:20 Europe/Madrid through 18:00 UTC.'
    severity: 2
    enabled: true
    evaluationFrequency: 'PT5M'
    windowSize: 'PT5M'
    overrideQueryTimeRange: 'PT20M'
    scopes: [
      workspaceResourceId
    ]
    targetResourceTypes: [
      'Microsoft.OperationalInsights/workspaces'
    ]
    autoMitigate: true
    resolveConfiguration: {
      autoResolved: true
      timeToResolve: 'PT10M'
    }
    checkWorkspaceAlertsStorageConfigured: false
    skipQueryValidation: false
    criteria: {
      allOf: [
        {
          query: dataFreshnessQuery
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
        scenario: 'identity-operations'
        operatingWindow: '08:20 Europe/Madrid - 18:00 UTC'
      }
    }
  }
}

output dataCollectionRuleId string = identityOpsDcr.id
output dataCollectionRuleAssociationIds array = [
  for index in range(0, length(targetMachineNames)): identityOpsAssociations[index].id
]
output tokenFailureAlertId string = tokenFailureAlert.id
output dataFreshnessAlertId string = dataFreshnessAlert.id
output targetMachineResourceIds array = targetMachineResourceIds
