// "Monthly image" for the demo without an image pipeline.
//
// A Marketplace image is already generalized. A managed disk created from it has never
// booted, so it is still generalized and can be published straight into an Azure Compute
// Gallery. Two consecutive Marketplace builds become version 1.0.0 (last month) and
// 2.0.0 (this month), which gives session host update a real patch level to move between.
// In production you would build these versions with Azure Image Builder or Packer.

@description('Name prefix, lowercase letters and digits.')
param prefix string

@description('Azure region.')
param location string

@description('Marketplace publisher of the source image.')
param publisher string

@description('Marketplace offer of the source image.')
param offer string

@description('Marketplace SKU of the source image.')
param sku string

@description('Gallery versions to create, oldest first. Each item: { name: \'1.0.0\', marketplaceVersion: \'26200.x.y\' }.')
@minLength(1)
param versions array

@description('Tags for every resource.')
param tags object

resource gallery 'Microsoft.Compute/galleries@2024-03-03' = {
  name: 'gal_${prefix}'
  location: location
  tags: tags
  properties: {
    description: 'Images for the AVD automated host pool demo'
  }
}

resource definition 'Microsoft.Compute/galleries/images@2024-03-03' = {
  parent: gallery
  name: 'win11-avd-multisession'
  location: location
  tags: tags
  properties: {
    osType: 'Windows'
    osState: 'Generalized'
    hyperVGeneration: 'V2'
    architecture: 'x64'
    identifier: {
      publisher: 'GetToTheCloud'
      offer: 'avd-demo'
      sku: sku
    }
    features: [
      {
        name: 'SecurityType'
        value: 'TrustedLaunchSupported' // lets the session host configuration use Trusted Launch
      }
    ]
  }
}

// One managed disk per Marketplace build, created straight from the platform image.
resource sourceDisks 'Microsoft.Compute/disks@2024-03-02' = [
  for v in versions: {
    name: 'disk-${prefix}-image-${replace(v.name, '.', '-')}'
    location: location
    tags: union(tags, { marketplaceVersion: v.marketplaceVersion })
    sku: {
      name: 'Standard_LRS'
    }
    properties: {
      osType: 'Windows'
      hyperVGeneration: 'V2'
      creationData: {
        createOption: 'FromImage'
        imageReference: {
          id: '/Subscriptions/${subscription().subscriptionId}/Providers/Microsoft.Compute/Locations/${location}/Publishers/${publisher}/ArtifactTypes/VMImage/Offers/${offer}/Skus/${sku}/Versions/${v.marketplaceVersion}'
        }
      }
    }
  }
]

// Publish each disk as a gallery image version. @batchSize(1) keeps the version
// numbers in order of creation, which reads better in the portal.
@batchSize(1)
resource imageVersions 'Microsoft.Compute/galleries/images/versions@2024-03-03' = [
  for (v, i) in versions: {
    parent: definition
    name: v.name
    location: location
    tags: union(tags, { marketplaceVersion: v.marketplaceVersion })
    properties: {
      publishingProfile: {
        replicaCount: 2 // the session host update docs recommend at least two replicas
        excludeFromLatest: false
        targetRegions: [
          {
            name: location
            regionalReplicaCount: 2
            storageAccountType: 'Standard_LRS'
          }
        ]
      }
      storageProfile: {
        osDiskImage: {
          source: {
            id: sourceDisks[i].id
          }
        }
      }
      safetyProfile: {
        allowDeletionOfReplicatedLocations: true
      }
    }
  }
]

@description('Resource ID of the image definition. Append /versions/<name> for a version.')
output definitionId string = definition.id

@description('Gallery image versions, in the same order as the input.')
output versions array = [
  for (v, i) in versions: {
    name: v.name
    marketplaceVersion: v.marketplaceVersion
    id: imageVersions[i].id
  }
]
