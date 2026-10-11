// Shared, typed settings for the demo. Imported by main.bicep and the modules,
// so a typo in a parameter file fails at build time instead of halfway through a deployment.

@export()
@description('What every session host in a pool looks like. Becomes the session host configuration.')
type sessionHostSettings = {
  @description('Prefix for VM and computer names. AVD appends -0, -1, ... The total name can be at most 15 characters.')
  @minLength(3)
  @maxLength(11)
  vmNamePrefix: string

  @description('VM size, for example Standard_D4ads_v5. Must support Gen2, Trusted Launch and premium storage.')
  vmSize: string

  @description('OS disk type.')
  osDiskType: 'Premium_LRS' | 'StandardSSD_LRS' | 'Standard_LRS'

  @description('Resource ID of the Azure Compute Gallery image version the hosts are built from.')
  imageVersionId: string

  @description('Resource ID of the subnet for the session hosts.')
  subnetId: string

  @description('Availability zones to spread hosts across. Leave empty for a regional deployment.')
  availabilityZones: int[]

  @description('Enroll the session hosts in Microsoft Intune when they join Microsoft Entra ID.')
  intuneEnrollment: bool

  @description('Key Vault secret URI that holds the local admin user name.')
  adminUsernameSecretUri: string

  @description('Key Vault secret URI that holds the local admin password.')
  adminPasswordSecretUri: string

  @description('Tags applied to every VM the pool creates.')
  vmTags: object
}

@export()
@description('How AVD creates and updates session hosts. Becomes the session host management policy.')
type managementPolicySettings = {
  @description('Windows time zone ID used for scheduled updates, for example W. Europe Standard Time.')
  timeZone: string

  @description('Batch size: the maximum number of hosts taken out of service at the same time during an update.')
  @minValue(1)
  maxVmsRemoved: int

  @description('Minutes users get between the warning message and the forced sign-out during an update.')
  @minValue(0)
  @maxValue(60)
  logOffDelayMinutes: int

  @description('Message users see before they are signed out for an update.')
  @maxLength(260)
  logOffMessage: string

  @description('Delete the original VM and OS disk after a host is replaced. False keeps the old disk as a rollback option.')
  deleteOriginalVm: bool

  @description('Put newly created hosts in drain mode, so you can check them before users land on them.')
  setDrainMode: bool

  @description('What to keep when host creation fails.')
  failedSessionHostCleanupPolicy: 'KeepAll' | 'KeepOne' | 'KeepNone'

  @description('Create a single canary host first to validate the configuration.')
  canaryPolicy: 'Auto' | 'Always' | 'Never'

  @description('Number of hosts the pool should have. Leave it out when autoscale owns the pool size.')
  @minValue(1)
  instanceCount: int?
}

@export()
@description('The dynamic autoscaling schedule. Times use the scaling plan time zone, in HH:mm.')
type scalingScheduleSettings = {
  @description('Schedule name.')
  name: string

  @description('Days the schedule applies to.')
  daysOfWeek: ('Monday' | 'Tuesday' | 'Wednesday' | 'Thursday' | 'Friday' | 'Saturday' | 'Sunday')[]

  @description('Start of ramp-up, HH:mm.')
  rampUpStart: string

  @description('Start of peak, HH:mm. Peak inherits the ramp-up capacity threshold and host pool sizes.')
  peakStart: string

  @description('Start of ramp-down, HH:mm.')
  rampDownStart: string

  @description('Start of off-peak, HH:mm. Off-peak inherits the ramp-down capacity threshold and host pool sizes.')
  offPeakStart: string

  @description('Ramp-up and peak: hosts that always exist, running or stopped.')
  @minValue(0)
  @maxValue(59)
  rampUpMinHosts: int

  @description('Ramp-up and peak: cap on running hosts.')
  @minValue(0)
  rampUpMaxHosts: int

  @description('Ramp-down and off-peak: hosts that always exist, running or stopped.')
  @minValue(0)
  @maxValue(59)
  rampDownMinHosts: int

  @description('Ramp-down and off-peak: cap on running hosts.')
  @minValue(0)
  rampDownMaxHosts: int

  @description('Ramp-up and peak: used capacity above this percentage adds hosts.')
  @minValue(1)
  @maxValue(100)
  rampUpCapacityThresholdPct: int

  @description('Ramp-down and off-peak: used capacity below this percentage removes empty hosts.')
  @minValue(1)
  @maxValue(100)
  rampDownCapacityThresholdPct: int

  @description('Share of the minimum host pool size that stays running. 100 means autoscale only creates and deletes.')
  @minValue(0)
  @maxValue(100)
  minimumActiveHostsPct: int
}

@export()
@description('Turns HH:mm into the { hour, minute } object the scaling plan API expects.')
func toTime(hhmm string) object => {
  hour: int(split(hhmm, ':')[0])
  minute: int(split(hhmm, ':')[1])
}
