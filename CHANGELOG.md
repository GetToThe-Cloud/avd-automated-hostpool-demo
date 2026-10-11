# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-10-12

### Added

- Bicep for two automated host pools built from a session host configuration:
  Pool A with a dynamic scaling plan, Pool B with session host update.
- Gallery image versions 1.0.0 and 2.0.0 made from two consecutive Marketplace
  builds, so session host update has a real patch level to move between.
- Two-phase deployment, so role assignments propagate before the session host
  configurations are validated.
- PowerShell scripts for every step of the demo: prerequisites, deployment,
  go/no-go check, autoscale phase control, session host update, live views,
  scale-in, reset and removal.
- KQL for autoscale decisions, the host count timeline, failed evaluations,
  session host update runs and errors.
