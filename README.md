# Job Alert Component for Salesforce Field Service

A lightweight, high-performance utility bar component that alerts dispatcher and internal users of high-priority jobs in their active territories.

## Features
- Real-time alerts using Salesforce Streaming API (empApi) or Smart Polling.
- Audio buzzer notification for critical alerts.
- Global acknowledgement and personal dismissal.
- Restoring dismissed alerts.
- Filter and view only selected Service Appointments on the Gantt chart.

## Deployment

### Salesforce DX (SFDX)
Deploy the source files directly to your target org:
```bash
sf project deploy start
```

### Metadata API (package.xml)
Deploy using your favorite deployment tool or Salesforce CLI:
```bash
sf project deploy start --manifest manifest/package.xml
```

## Post-Deployment Setup
1. Assign the **Job Alert Component Access** Permission Set to your users.
2. Add the **High Priority Job Alerts** LWC (`jobAlertUtility`) to your Utility Bar in the Lightning App Builder.
