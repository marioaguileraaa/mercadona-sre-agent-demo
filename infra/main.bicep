targetScope = 'resourceGroup'

@description('Deployment label used by Azure Developer CLI.')
param environmentName string = 'mercadona-sre-demo'

@description('Azure region for all regional resources.')
param location string = 'eastus2'

@description('Existing demo resource group. Deployment updates it idempotently.')
param resourceGroupName string = 'rg-mercadona-sre-agent-v1'

@description('Backend image. The deployment script replaces the placeholder after remote ACR build.')
param apiImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

@description('Frontend image. The deployment script replaces the placeholder after remote ACR build.')
param frontendImage string = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'

var placeholderImage = 'mcr.microsoft.com/azuredocs/containerapps-helloworld:latest'
var apiIsPlaceholder = apiImage == placeholderImage
var tags = {
  purpose: 'sre-agent-demo'
  environment: 'demo'
  dataClassification: 'synthetic'
  scenario: 'synthetic-retail'
  'azd-env-name': environmentName
}
var token = uniqueString(subscription().subscriptionId, resourceGroupName)
var registryName = 'acrmrcdemo${token}'
var environmentNameResource = 'cae-mercadona-demo-v1'
var backendName = 'ca-mercadona-retail-api'
var frontendName = 'ca-mercadona-retail-web'
var logAnalyticsName = 'law-mercadona-demo-v1'
var applicationInsightsName = 'appi-mercadona-demo-v1'
var appIdentityName = 'id-mercadona-app-v1'
var sreIdentityName = 'id-mercadona-sre-v1'
var sreAgentName = 'sre-agent-mercadona-v1'

var acrPullRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '7f951dda-4ed3-4680-a7ca-43fe172d538d')
var readerRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
var logAnalyticsReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '73c42c96-874c-492b-b04d-ab87d138a893')
var monitoringReaderRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '43d0d8ad-25c7-4714-9337-8ba259a9fe05')
var containerAppsContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '358470bc-b998-42bd-ab17-a7e34c199c0f')
var monitoringContributorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', '749f88d5-cbae-40b8-bcfc-e573ddc772fa')
var sreAgentAdministratorRoleId = subscriptionResourceId('Microsoft.Authorization/roleDefinitions', 'e79298df-d852-4c6d-84f9-5d13249d1e55')

module observability 'core/observability.bicep' = {
  name: 'observability'
  params: {
    location: location
    logAnalyticsName: logAnalyticsName
    applicationInsightsName: applicationInsightsName
    tags: tags
  }
}

module registry 'core/host/container-registry.bicep' = {
  name: 'registry'
  params: {
    name: registryName
    location: location
    tags: tags
  }
}

resource appIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: appIdentityName
  location: location
  tags: tags
}

resource sreIdentity 'Microsoft.ManagedIdentity/userAssignedIdentities@2023-01-31' = {
  name: sreIdentityName
  location: location
  tags: tags
}

resource registryExisting 'Microsoft.ContainerRegistry/registries@2023-07-01' existing = {
  name: registryName
}

resource appAcrPull 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: registryExisting
  name: guid(registryExisting.id, appIdentity.id, acrPullRoleId)
  properties: {
    principalId: appIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: acrPullRoleId
  }
  dependsOn: [
    registry
  ]
}

module containerEnvironment 'core/host/container-apps-environment.bicep' = {
  name: 'container-environment'
  params: {
    name: environmentNameResource
    location: location
    tags: tags
    logAnalyticsCustomerId: observability.outputs.workspaceCustomerId
    logAnalyticsSharedKey: observability.outputs.workspaceSharedKey
  }
}

module backend 'core/host/container-app.bicep' = {
  name: 'backend'
  params: {
    name: backendName
    location: location
    tags: union(tags, { 'azd-service-name': 'api' })
    environmentId: containerEnvironment.outputs.id
    registryServer: registry.outputs.loginServer
    managedIdentityId: appIdentity.id
    containerName: 'mercadona-retail-api'
    containerImage: apiImage
    targetPort: apiIsPlaceholder ? 80 : 8080
    probePath: apiIsPlaceholder ? '/' : '/healthz'
    maxReplicas: 1
    env: [
      {
        name: 'ASPNETCORE_ENVIRONMENT'
        value: 'Production'
      }
      {
        name: 'DEMO_CART_MEMORY_MB_PER_ADD'
        value: '0'
      }
      {
        name: 'DEMO_CART_MEMORY_MAX_MB'
        value: '640'
      }
    ]
  }
  dependsOn: [
    appAcrPull
  ]
}

module frontend 'core/host/container-app.bicep' = {
  name: 'frontend'
  params: {
    name: frontendName
    location: location
    tags: union(tags, { 'azd-service-name': 'frontend' })
    environmentId: containerEnvironment.outputs.id
    registryServer: registry.outputs.loginServer
    managedIdentityId: appIdentity.id
    containerName: 'mercadona-retail-web'
    containerImage: frontendImage
    targetPort: 80
    probePath: '/'
    cpu: '0.25'
    memory: '0.5Gi'
    maxReplicas: 2
    env: [
      {
        name: 'BACKEND_URL'
        value: 'https://${backend.outputs.fqdn}'
      }
    ]
  }
  dependsOn: [
    appAcrPull
  ]
}

resource actionGroup 'Microsoft.Insights/actionGroups@2023-01-01' = {
  name: 'ag-mercadona-sre-demo'
  location: 'global'
  tags: tags
  properties: {
    groupShortName: 'mrc-sre-demo'
    enabled: true
  }
}

resource backendResource 'Microsoft.App/containerApps@2024-03-01' existing = {
  name: backendName
}

resource cartMemoryAlert 'Microsoft.Insights/metricAlerts@2018-03-01' = {
  name: 'alert-mercadona-cart-memory'
  location: 'global'
  tags: tags
  properties: {
    description: 'Synthetic retail backend working set exceeded 600 MiB in the controlled cart-memory demo.'
    severity: 2
    enabled: true
    scopes: [
      backendResource.id
    ]
    evaluationFrequency: 'PT1M'
    windowSize: 'PT5M'
    targetResourceType: 'Microsoft.App/containerApps'
    targetResourceRegion: location
    criteria: {
      'odata.type': 'Microsoft.Azure.Monitor.SingleResourceMultipleMetricCriteria'
      allOf: [
        {
          name: 'CartMemoryWorkingSet'
          metricNamespace: 'Microsoft.App/containerApps'
          metricName: 'WorkingSetBytes'
          operator: 'GreaterThan'
          threshold: 629145600
          timeAggregation: 'Maximum'
          criterionType: 'StaticThresholdCriterion'
        }
      ]
    }
    autoMitigate: true
    actions: [
      {
        actionGroupId: actionGroup.id
      }
    ]
  }
  dependsOn: [
    backend
  ]
}

resource sreReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreIdentity.id, readerRoleId)
  properties: {
    principalId: sreIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: readerRoleId
  }
}

resource sreLogReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreIdentity.id, logAnalyticsReaderRoleId)
  properties: {
    principalId: sreIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: logAnalyticsReaderRoleId
  }
}

resource sreMonitoringReader 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreIdentity.id, monitoringReaderRoleId)
  properties: {
    principalId: sreIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: monitoringReaderRoleId
  }
}

resource sreContainerAppsContributor 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  name: guid(resourceGroup().id, sreIdentity.id, containerAppsContributorRoleId)
  properties: {
    principalId: sreIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: containerAppsContributorRoleId
  }
}

module sreMonitoringContributor 'core/subscription-role-assignment.bicep' = {
  name: 'sre-monitoring-contributor'
  scope: subscription()
  params: {
    principalId: sreIdentity.properties.principalId
    roleDefinitionId: monitoringContributorRoleId
    principalType: 'ServicePrincipal'
  }
}

resource sreAgent 'Microsoft.App/agents@2026-01-01' = {
  name: sreAgentName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned, UserAssigned'
    userAssignedIdentities: {
      '${sreIdentity.id}': {}
    }
  }
  properties: {
    actionConfiguration: {
      accessLevel: 'Low'
      identity: sreIdentity.id
      mode: 'Review'
    }
    knowledgeGraphConfiguration: {
      identity: sreIdentity.id
      managedResources: [
        resourceGroup().id
      ]
    }
    defaultModel: {
      provider: 'Anthropic'
      name: 'Automatic'
    }
    incidentManagementConfiguration: {
      type: 'AzMonitor'
      connectionName: 'azmonitor'
    }
    logConfiguration: {
      applicationInsightsConfiguration: {
        appId: observability.outputs.applicationInsightsAppId
        connectionString: observability.outputs.applicationInsightsConnectionString
      }
    }
    upgradeChannel: 'Preview'
  }
  dependsOn: [
    sreReader
    sreLogReader
    sreMonitoringReader
    sreContainerAppsContributor
    sreMonitoringContributor
    cartMemoryAlert
  ]
}

resource sreIdentityAgentAdministrator 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: sreAgent
  name: guid(sreAgent.id, sreIdentity.id, sreAgentAdministratorRoleId)
  properties: {
    principalId: sreIdentity.properties.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: sreAgentAdministratorRoleId
  }
}

resource logAnalyticsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'log-analytics'
  properties: {
    dataConnectorType: 'LogAnalytics'
    dataSource: observability.outputs.workspaceId
    extendedProperties: {
      armResourceId: observability.outputs.workspaceId
      resource: {
        name: observability.outputs.workspaceName
      }
    }
    identity: sreIdentity.id
  }
}

resource appInsightsConnector 'Microsoft.App/agents/connectors@2025-05-01-preview' = {
  parent: sreAgent
  name: 'application-insights'
  properties: {
    dataConnectorType: 'AppInsights'
    dataSource: observability.outputs.applicationInsightsId
    extendedProperties: {
      armResourceId: observability.outputs.applicationInsightsId
      resource: {
        name: observability.outputs.applicationInsightsName
      }
      appId: observability.outputs.applicationInsightsAppId
    }
    identity: sreIdentity.id
  }
}

output AZURE_LOCATION string = location
output AZURE_RESOURCE_GROUP string = resourceGroup().name
output AZURE_CONTAINER_REGISTRY_NAME string = registry.outputs.name
output AZURE_CONTAINER_REGISTRY_ENDPOINT string = registry.outputs.loginServer
output API_BASE_URL string = 'https://${backend.outputs.fqdn}'
output FRONTEND_URL string = 'https://${frontend.outputs.fqdn}'
output LOG_ANALYTICS_WORKSPACE_ID string = observability.outputs.workspaceId
output APPLICATION_INSIGHTS_ID string = observability.outputs.applicationInsightsId
output SRE_AGENT_ID string = sreAgent.id
output SRE_AGENT_IDENTITY_CLIENT_ID string = sreIdentity.properties.clientId
