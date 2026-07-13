targetScope = 'resourceGroup'

@description('Azure region for the Consumption Logic App.')
param location string

@description('Name of the Consumption Logic App.')
param logicAppName string

@description('Name of the existing Azure SRE Agent.')
param agentName string

@secure()
@description('Protected Azure SRE Agent HTTP trigger URL.')
param sreTriggerUrl string

var standardUserRoleId = '2d84a65a-63b2-4343-bbb6-31105d857bc1'
var tags = {
  purpose: 'sre-agent-demo'
  environment: 'demo'
  dataClassification: 'synthetic'
  scenario: 'synthetic-retail'
}

resource agent 'Microsoft.App/agents@2026-01-01' existing = {
  name: agentName
}

resource bridge 'Microsoft.Logic/workflows@2019-05-01' = {
  name: logicAppName
  location: location
  tags: tags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    state: 'Enabled'
    parameters: {
      sreTriggerUrl: {
        value: sreTriggerUrl
      }
    }
    definition: {
      '$schema': 'https://schema.management.azure.com/providers/Microsoft.Logic/schemas/2016-06-01/workflowdefinition.json#'
      contentVersion: '1.0.0.0'
      parameters: {
        sreTriggerUrl: {
          type: 'SecureString'
        }
      }
      triggers: {
        incoming_webhook: {
          type: 'Request'
          kind: 'Http'
          inputs: {
            schema: {
              type: 'object'
              additionalProperties: true
            }
          }
        }
      }
      actions: {
        forward_to_sre_agent: {
          type: 'Http'
          runAfter: {}
          operationOptions: 'DisableAsyncPattern'
          runtimeConfiguration: {
            secureData: {
              properties: [
                'inputs'
              ]
            }
          }
          inputs: {
            method: 'POST'
            retryPolicy: {
              type: 'none'
            }
            uri: '@parameters(\'sreTriggerUrl\')'
            headers: {
              'Content-Type': 'application/json'
            }
            body: '@triggerBody()'
            authentication: {
              type: 'ManagedServiceIdentity'
              audience: 'https://azuresre.dev'
            }
          }
        }
        respond_to_caller: {
          type: 'Response'
          kind: 'Http'
          runAfter: {
            forward_to_sre_agent: [
              'Succeeded'
              'Failed'
              'TimedOut'
            ]
          }
          inputs: {
            statusCode: '@coalesce(outputs(\'forward_to_sre_agent\')?[\'statusCode\'], 502)'
            headers: {
              'Content-Type': '@coalesce(outputs(\'forward_to_sre_agent\')?[\'headers\']?[\'Content-Type\'], outputs(\'forward_to_sre_agent\')?[\'headers\']?[\'content-type\'], \'application/json\')'
            }
            body: '@coalesce(outputs(\'forward_to_sre_agent\')?[\'body\'], json(\'{"error":"sre_trigger_bridge_failure"}\'))'
          }
        }
      }
      outputs: {}
    }
  }
}

resource bridgeStandardUser 'Microsoft.Authorization/roleAssignments@2022-04-01' = {
  scope: agent
  name: guid(agent.id, bridge.id, standardUserRoleId)
  properties: {
    principalId: bridge.identity.principalId
    principalType: 'ServicePrincipal'
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', standardUserRoleId)
  }
}

output logicAppName string = bridge.name
output logicAppPrincipalId string = bridge.identity.principalId
