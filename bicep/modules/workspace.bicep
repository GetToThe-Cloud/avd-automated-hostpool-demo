// The workspace that publishes both demo desktops to the users.

@description('Workspace name.')
param name string

@description('Azure region.')
param location string

@description('Friendly name users see in Windows App.')
param friendlyName string

@description('Application groups to publish.')
param appGroupIds array

@description('Log Analytics workspace resource ID for diagnostics.')
param logAnalyticsWorkspaceId string

@description('Tags for every resource.')
param tags object

resource workspace 'Microsoft.DesktopVirtualization/workspaces@2026-04-01-preview' = {
  name: name
  location: location
  tags: tags
  properties: {
    friendlyName: friendlyName
    applicationGroupReferences: appGroupIds
  }
}

resource diagnostics 'Microsoft.Insights/diagnosticSettings@2021-05-01-preview' = {
  name: 'to-log-analytics'
  scope: workspace
  properties: {
    workspaceId: logAnalyticsWorkspaceId
    logs: [
      for category in ['Checkpoint', 'Error', 'Management', 'Feed']: {
        category: category
        enabled: true
      }
    ]
  }
}

@description('Workspace resource ID.')
output id string = workspace.id
