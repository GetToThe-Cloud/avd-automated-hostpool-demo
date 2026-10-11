// Dynamic autoscaling: a scaling plan that creates and deletes hosts
// (CreateDeletePowerManage), assigned to one automated host pool.

import { scalingScheduleSettings, toTime } from 'types.bicep'

@description('Scaling plan name.')
param name string

@description('Azure region. Must match the host pool metadata region.')
param location string

@description('Windows time zone ID for the schedule.')
param timeZone string

@description('Resource ID of the automated host pool to scale.')
param hostPoolId string

@description('Hosts with this tag are left alone by autoscale.')
param exclusionTag string = 'excludeFromScaling'

@description('Schedule settings.')
param schedule scalingScheduleSettings

@description('Tags for every resource.')
param tags object

resource plan 'Microsoft.DesktopVirtualization/scalingPlans@2026-04-01-preview' = {
  name: name
  location: location
  tags: tags
  properties: {
    friendlyName: 'Dynamic autoscaling demo'
    description: 'Creates and deletes session hosts based on used capacity.'
    timeZone: timeZone
    hostPoolType: 'Pooled'
    exclusionTag: exclusionTag
    hostPoolReferences: [
      {
        hostPoolArmPath: hostPoolId
        scalingPlanEnabled: true // switch off before a session host update on this pool
      }
    ]
  }

  resource days 'pooledSchedules' = {
    name: schedule.name
    properties: {
      daysOfWeek: schedule.daysOfWeek
      scalingMethod: 'CreateDeletePowerManage' // dynamic: create and delete, not only start and stop
      createDelete: {
        rampUpMinimumHostPoolSize: schedule.rampUpMinHosts // carried into peak
        rampUpMaximumHostPoolSize: schedule.rampUpMaxHosts
        rampDownMinimumHostPoolSize: schedule.rampDownMinHosts // carried into off-peak
        rampDownMaximumHostPoolSize: schedule.rampDownMaxHosts
      }
      rampUpStartTime: toTime(schedule.rampUpStart)
      rampUpLoadBalancingAlgorithm: 'BreadthFirst'
      rampUpMinimumHostsPct: schedule.minimumActiveHostsPct
      rampUpCapacityThresholdPct: schedule.rampUpCapacityThresholdPct // peak inherits this
      peakStartTime: toTime(schedule.peakStart)
      peakLoadBalancingAlgorithm: 'BreadthFirst'
      rampDownStartTime: toTime(schedule.rampDownStart)
      rampDownLoadBalancingAlgorithm: 'DepthFirst' // pack users so empty hosts can go
      rampDownMinimumHostsPct: schedule.minimumActiveHostsPct
      rampDownCapacityThresholdPct: schedule.rampDownCapacityThresholdPct // off-peak inherits this
      rampDownForceLogoffUsers: false
      rampDownStopHostsWhen: 'ZeroSessions'
      rampDownWaitTimeMinutes: 30
      rampDownNotificationMessage: 'This desktop is being consolidated. Please save your work and sign out.'
      offPeakStartTime: toTime(schedule.offPeakStart)
      offPeakLoadBalancingAlgorithm: 'DepthFirst'
    }
  }
}

@description('Scaling plan resource ID.')
output id string = plan.id

@description('Scaling plan name.')
output name string = plan.name

@description('Schedule name, used by the demo scripts to shift the phases.')
output scheduleName string = plan::days.name
