// Network for the session hosts: one subnet, an NSG without inbound rules
// (AVD uses reverse connect, nothing needs to come in) and a NAT gateway for
// explicit outbound access. Dynamic autoscaling downloads the agent from
// wvdhpustgr0prod.blob.core.windows.net, so outbound internet is not optional.

@description('Name prefix for the network resources.')
param prefix string

@description('Azure region.')
param location string

@description('Address space of the virtual network.')
param vnetAddressPrefix string

@description('Address prefix of the session host subnet.')
param subnetAddressPrefix string

@description('Tags for every resource.')
param tags object

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-07-01' = {
  name: 'nsg-${prefix}-sessionhosts'
  location: location
  tags: tags
  properties: {
    securityRules: []
  }
}

resource natIp 'Microsoft.Network/publicIPAddresses@2024-07-01' = {
  name: 'pip-${prefix}-natgw'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
    publicIPAddressVersion: 'IPv4'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-07-01' = {
  name: 'ng-${prefix}'
  location: location
  tags: tags
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 4
    publicIpAddresses: [
      {
        id: natIp.id
      }
    ]
  }
}

resource vnet 'Microsoft.Network/virtualNetworks@2024-07-01' = {
  name: 'vnet-${prefix}'
  location: location
  tags: tags
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddressPrefix
      ]
    }
    subnets: [
      {
        name: 'snet-sessionhosts'
        properties: {
          addressPrefix: subnetAddressPrefix
          defaultOutboundAccess: false // private subnet, outbound goes through the NAT gateway
          networkSecurityGroup: {
            id: nsg.id
          }
          natGateway: {
            id: natGateway.id
          }
        }
      }
    ]
  }
}

@description('Resource ID of the session host subnet.')
output subnetId string = vnet.properties.subnets[0].id
