# Alert Center Component for Salesforce Field Service

A reusable Field Service package that alerts **dispatchers** of high-priority jobs and field-resource panic events in the Service Territories they currently have loaded on the Gantt.

Dispatchers use the **FS Alert Center** utility bar LWC (`fsAlertCenterUtility`). Technicians raise panic events from the **FS Mobile Panic Button** global action (`fsMobilePanicButton`). Architecture, data model, per-tab action design, and sequence detail live in `docs/FS_Alert_Center_Design.md`.

## Features

- Configurable **Priority Alerts**, **Panic Alerts**, or **both** via Custom Metadata (no code change).
- High Priority Alerts created from the Service Appointment trigger when parent Work Order / Work Order Line Item priority matches a comma-separated list.
- Offline-capable Field Service Mobile SOS that creates a Panic Alert with GPS, Service Resource, optional Nature of the Emergency, and primary territory.
- Utility list filtered by the dispatcher’s **Gantt-loaded Service Territories**.
- Real-time updates via Change Data Capture and empApi (Lightning). Experience Cloud uses 20-second polling.
- Audio buzzer and utility-bar badge on new relevant alerts.
- Global **acknowledge** and personal **dismiss**, with **per-type** Dismiss All and restore of today’s dismissals.
- Tabs **Priority Alerts (n)** and **Panic Alerts (n)**; Sync, Undo, and Dismiss All sit on each type (Salesforce utility chrome keeps the combined `Alert Center (n)` label).
- Job-card filter icon publishes a Field Service event that **creates and loads a temporary Gantt filter** for that Service Appointment.
- Packaged list views for All, High Priority, and Panic alerts.

## End-to-end flow

```mermaid
flowchart TD
    subgraph config [Configuration]
        CMDT[Default_Setting CMDT]
        Bypass[Trigger bypass setting]
    end

    subgraph create [Alert creation]
        SA[Service Appointment insert or parent lookup change]
        Trig[FS_ServiceAppointmentTrigger]
        SOS[Technician SOS on mobile]
        GPS[Device GPS plus GraphQL resource]
        Rec[FS_AlertCenter__c record]
    end

    subgraph notify [Dispatcher notification]
        CDC[Change Data Capture]
        Emp[empApi or 20s poll]
        Util[fsAlertCenterUtility]
        Terr[Gantt loaded territories]
    end

    subgraph act [Dispatcher action]
        Ack[Acknowledge globally]
        Dis[Dismiss one personally]
        TabAct[Per-tab Sync Undo Dismiss All]
        Filt[Publish Gantt filter event]
    end

    CMDT --> Trig
    Bypass --> Trig
    SA --> Trig
    Trig --> Rec
    SOS --> GPS
    GPS --> Rec
    Rec --> CDC
    CDC --> Emp
    Emp --> Util
    Terr --> Util
    CMDT --> Util
    Util --> Ack
    Util --> Dis
    Util --> TabAct
    Util --> Filt
```

## Configurability: Priority Alerts, Panic Alerts, or both

Edit Custom Metadata **FS Alert Center Setting** record **Default Setting** (`FS_Alert_Center_Setting.Default_Setting`).

| Field | Packaged default | What it controls |
|---|---|---|
| `Priority_Alerts_Enabled__c` | true | **On:** trigger may insert High Priority Alerts; utility shows Priority Alerts. **Off:** no job-alert inserts; Priority tab hidden. |
| `Panic_Alerts_Enabled__c` | true | **On:** utility shows Panic Alerts. **Off:** Panic tab hidden. Mobile SOS can still create records; they will not appear in the utility. |
| `Alert_Priorities__c` | `High,Critical,Jeopardy` | Comma-separated, case-insensitive list matched to Work Order Line Item Priority, then Work Order Priority. |

Utility layout from the two flags:

| Priority | Panic | What dispatchers see |
|---|---|---|
| true | true | Tabs **Priority Alerts (n)** and **Panic Alerts (n)**, each with its own Sync / Undo / Dismiss All toolbar |
| true | false | Priority list plus that type’s toolbar |
| false | true | Panic list plus that type’s toolbar |
| false | false | Empty panel |

The Salesforce utility item label stays `Alert Center (n)` (combined count of enabled types). Each tab label carries **that type’s** count. If only Panic is enabled, the panel opens on the Panic list.

Turning Panic off in CMDT does **not** disable the mobile SOS button. It only hides Panic cards in the dispatcher utility.

## Criteria for alert creation

### High Priority Alert (Priority Alerts)

Handler: `FS_ServiceAppointmentTrigger` → `FS_ServiceAppointmentTriggerHandler` on after insert and after update.

All of the following must be true:

1. Hierarchy custom setting **FS Trigger Bypass Setting** → `Bypass_Service_Appointment_Trigger__c` is not true for the running user.
2. `Default_Setting` exists and `Priority_Alerts_Enabled__c` is true.
3. The Service Appointment is **inserted**, or `FS_Work_Order__c` / `FS_Work_Order_Line_Item__c` **changed** (parent lookups populated or re-parented). Changing only WO/WOLI priority without those lookup changes does not create a new alert.
4. No existing `FS_AlertCenter__c` for that Service Appointment (one job alert per SA).
5. Computed priority is not blank: **Work Order Line Item.Priority** if present, otherwise **Work Order.Priority**.
6. That value (trimmed, lowercased) is in `Alert_Priorities__c`.

Created record: `Alert_Type__c = High Priority Alert`, `Status__c = New`, Service Appointment, Service Territory from the appointment.

Before insert/update, the same trigger copies `ParentRecordId` onto `FS_Work_Order__c` and/or `FS_Work_Order_Line_Item__c` so those lookups exist for priority evaluation.

The job **card** shows `ServiceAppointment.Priority__c`. Creation uses **WO/WOLI Priority**. Keep those aligned in the org if you want the card to match the trigger.

### Panic Alert

Created only from `fsMobilePanicButton` with UI API `createRecord` (no Apex), so it can run **offline** after priming.

1. Optional **Nature of the Emergency** combobox (not required). Values: Medical crisis, Physical assault, Threat of violence, Environmental accident. Values are hardcoded to match the picklist so extra UI API priming is not required.
2. Device GPS (`navigator.geolocation`, high accuracy, 10 second timeout).
3. GraphQL: Service Resource whose `RelatedRecordId` is the current user.
4. GraphQL: Service Territory Members; first with Territory Type `P` or `Primary` is stored as `Service_Territory__c`. If none, territory is left blank.
5. Insert: `Alert_Type__c = Panic Alert`, `Status__c = New`, Panic Service Resource, latitude, longitude, optional territory and nature.

If the user has no Service Resource, SOS shows an error and does not insert.

A Panic Alert **without** `Service_Territory__c` is stored but **never shown** in the utility, because the utility always filters on Gantt territories.

Prime these objects in the Field Service Mobile Offline Brief:

- `FS_AlertCenter__c`
- `ServiceResource`
- `ServiceTerritoryMember`

## Gantt Service Territory filtration

The utility does not have its own territory picker. It **inherits the territories the dispatcher has loaded on the Field Service Gantt**.

Apex reads `FSL__User_Setting_Territory__c` where `FSL__User_Setting__r.FSL__User__c` is the current user, then returns alerts with:

`Service_Territory__c IN` that Id set

If the dispatcher has loaded **no** territories, the utility shows **no** alerts.

Use the **Sync** (refresh) icon on the Priority or Panic toolbar after changing Gantt-loaded territories so the query picks up the new set.

Matching is exact on the alert’s territory. Parent/child territory trees are not expanded unless those territories are also loaded on the Gantt.

Additional visibility rules (on top of territory):

- Status is `New`, **or** Status is `Acknowledged` **and** the current user last modified the record (the acknowledger).
- The current user does not have an `FS_Alert_Dismissal__c` row for that alert.
- The alert type is enabled in CMDT.

## Utility layout and per-tab actions

The inner panel no longer has a duplicate **Alert Center (n)** header with shared Sync / Undo / Dismiss All. Salesforce utility chrome already shows `Alert Center (n)`. Experience Cloud (`isCommunityMode`) keeps only a minimize control so the floating panel can close.

Each enabled type has its own toolbar **above that type’s cards**:

| Control | Icon | Scope |
|---|---|---|
| **Sync** | refresh | Reloads **all** enabled types from Gantt territories (`loadAlerts`). Same query either tab; the icon is repeated so it is always next to the list you are looking at. |
| **Undo** | undo | Restores **today’s** personal dismissals for **that type only**. |
| **Dismiss All** | clear | Personally dismisses **New** cards of **that type only**. Skips acknowledged cards. |

Tab labels (when both types are enabled):

- `Priority Alerts (n)` — `n` is the count of High Priority Alert cards currently visible to this user
- `Panic Alerts (n)` — `n` is the count of Panic Alert cards currently visible to this user

Empty copy is type-specific: “No priority alerts match your loaded filters.” / “No panic alerts match your loaded filters.”

Internal tab values remain `jobs` and `panic`. Toolbar buttons pass the picklist API value via `data-alert-type`:

- Priority toolbar: `High Priority Alert`
- Panic toolbar: `Panic Alert`

```mermaid
flowchart LR
    Chrome[Utility chrome Alert Center n]
    PriTab[Priority Alerts n]
    PanicTab[Panic Alerts n]
    PriBar[Sync Undo Dismiss All]
    PanicBar[Sync Undo Dismiss All]
    PriCards[High Priority cards]
    PanicCards[Panic cards]

    Chrome --> PriTab
    Chrome --> PanicTab
    PriTab --> PriBar
    PriBar --> PriCards
    PanicTab --> PanicBar
    PanicBar --> PanicCards
```

### Why Dismiss All and Undo are per type

A shared header Dismiss All used whichever list `activeTab` pointed at. If the dispatcher stayed on Priority Alerts, Panic **Dismiss All** was never the header’s target even when they thought they were clearing panic. Undo deleted **all** of today’s `FS_Alert_Dismissal__c` rows for the user, so restoring Priority also restored Panic (and the reverse).

Implementation:

1. `handleDismissAll` reads `event.currentTarget.dataset.alertType` and dismisses only **New** cards from `jobAlerts` or `panicAlerts`.
2. `handleUndoDismissAll` calls `undoAllDismissals(alertType)`.
3. Apex deletes today’s dismissals for the current user where `AlertCenter__r.Alert_Type__c` equals that value. Blank or unknown types are ignored (no deletes).
4. `dismissAllAlerts(List<Id>)` is unchanged; the LWC only sends IDs for the chosen type.

Card-level Acknowledge and Dismiss are unchanged (one record at a time).

## Acknowledge, dismiss, and restore

```mermaid
stateDiagram-v2
    [*] --> New: Job trigger or SOS create
    New --> Acknowledged: Acknowledge
    Acknowledged --> New: Dismiss while acknowledged
    New --> Hidden: Personal dismissal record
    Hidden --> New: Restore todays dismissals for that type
```

| Action | Scope | Behavior |
|---|---|---|
| **Acknowledge** (check icon) | Global | Sets Status to `Acknowledged`. Other dispatchers lose the card (they are not LastModifiedBy). The acknowledger still sees it. |
| **Dismiss** one (close icon) on a **New** alert | Personal | Inserts `FS_Alert_Dismissal__c` for this user. Others still see the alert. |
| **Dismiss** one on an **Acknowledged** alert | Global revert | Sets Status back to `New` (no dismissal row). The alert returns to other dispatchers in matching territories. |
| **Dismiss All** (clear icon on a type toolbar) | Personal, that type | Dismisses **New** cards of that type (Priority or Panic). Skips acknowledged cards. Does not touch the other type. |
| **Restore** (undo icon on a type toolbar) | Personal, that type | Deletes this user’s dismissal rows with `CreatedDate = TODAY` **and** `AlertCenter__r.Alert_Type__c` matching that toolbar. Older dismissals and the other type are not restored. |

## Dynamic Gantt filter from the job card

On a High Priority (Priority Alerts) card, the filter icon calls `FS_AlertCenterUtilityController.createTemporaryGanttFilter`.

That method publishes Field Service platform event `FSL__CreateFilterEvent__e`:

- Appointment Ids: JSON array with that Service Appointment Id
- Filter name: `{AppointmentNumber} - Priority Alert`
- Category: `GENERAL`
- Load immediately: true

The Gantt listens for the event, creates a **temporary filter**, and loads it so the board shows that appointment. Panic cards do not include this control.

## List views

Open the **FS Alert Centers** tab. Packaged list views (Everything scope — **not** Gantt-filtered):

| API name | Label | Filter | Typical use |
|---|---|---|---|
| `All` | All | none | Full columns including Nature and GPS |
| `FS_All_Alert_Centers` | FS All Alert Centers | none | Day-to-day list without Nature/GPS |
| `FS_All_High_Priority_Alerts` | All High Priority Alerts | Alert Type = High Priority Alert | Job alerts; Service Appointment column |
| `FS_All_Panic_Alerts` | All Panic Alerts | Alert Type = Panic Alert | Panic resource and Nature columns |

FS Alert Dismissals: `All` and `FS_All_Alert_Dismissals`.

Use the **utility** for live, territory-scoped work. Use **list views** for search and audit of records the user can access via sharing and the permission set.

## Dispatcher card contents

**Priority Alerts:** appointment number (opens the SA), Gantt filter, copy appointment number, SA Priority, Early Start, Due Date, Territory, Created, Address (Street and City).

**Panic:** resource name (opens the Service Resource). Shown only when populated: Phone/Mobile, Employee Number, Nature of the Emergency. Always: Territory, Created. If GPS exists: **Reported Location** map pin.

## Real-time behaviour

- Lightning: subscribe to `/data/FS_AlertCenter__ChangeEvent`. CREATE reloads with toast and buzzer; UPDATE reloads silently.
- Experience Cloud / `isCommunityMode`: poll `getActiveAlerts` every 20 seconds.
- New job toast: warning, sticky. New panic toast: error, sticky.
- Utility label: `Alert Center` or `Alert Center (n)`. New relevant alerts highlight the utility item and play `FS_AlertBuzzer`.

## Security and access

Assign permission set **FS Alert Center Component Access** (`FS_AlertCenter_Component_Access`).

It includes Apex access, Alert Center and Dismissal CRUD, related FLS (including Nature of the Emergency), User Phone and Employee Number read, Service Resource and Service Territory Member read, and object tabs.

Utility queries/DML run in system mode so dispatchers see alerts in **loaded Gantt territories** without each alert being shared to them. CMDT reads and some trigger queries use `WITH SECURITY_ENFORCED`.

## Obtain the source (clone, copy, or retrieve)

Do **not** deploy from a Google Drive placeholder copy if files are online-only. Use a full local clone or an explicit retrieve.

### Clone from Git

From a machine with Git, in the parent folder where you want the project:

```bash
git clone <REMOTE_REPOSITORY>
cd job-alert-component
```

Replace `<REMOTE_REPOSITORY>` with your team’s Git remote (SSH or HTTPS). Confirm `sfdx-project.json`, `force-app/`, and `manifest/package.xml` are present.

If you already have a clone:

```bash
git pull
```

### Copy the project folder

Copy the entire repository directory, including:

- `sfdx-project.json`
- `force-app/`
- `manifest/package.xml`
- `docs/` (optional, documentation only)

Exclude `.sfdx/`, `.sf/`, and `node_modules/` if present. Those are local CLI state, not package source.

### Retrieve the metadata from an org that already has it

If the package is already in a source org and you need a local project:

```bash
sf project retrieve start --manifest manifest/package.xml --target-org <SOURCE_ORG_ALIAS>
```

That pulls every member listed in `manifest/package.xml` into `force-app/`.

## Deploy to an org

Prerequisites: Salesforce CLI, a DX project (`sfdx-project.json`), and an authorized org. Field Service (FSL) must already be in the target org (`FSL__User_Setting_Territory__c`, `FSL__CreateFilterEvent__e`).

Authorize (example):

```bash
sf org login web --alias <TARGET_ORG_ALIAS>
```

### Deploy the full package (recommended)

```bash
sf project deploy start --manifest manifest/package.xml --target-org <TARGET_ORG_ALIAS>
```

If the sandbox has **source tracking** and the CLI reports conflicts with org copies of the same components, overwrite the org with local source:

```bash
sf project deploy start --manifest manifest/package.xml --target-org <TARGET_ORG_ALIAS> --ignore-conflicts
```

### Deploy the default package directory

```bash
sf project deploy start --source-dir force-app --target-org <TARGET_ORG_ALIAS>
```

### Deploy one component

```bash
sf project deploy start --source-dir force-app/main/default/lwc/fsAlertCenterUtility --target-org <TARGET_ORG_ALIAS>
```

`manifest/package.xml` is the supported inventory for a complete install (Apex, LWCs, objects, CMDT, layouts including **FS Mobile Global Layout**, quick action, list views, tabs, flexipages, CDC member, static resource, permission set).

The global publisher layout includes the panic action in **Mobile and Lightning Actions** (`platformActionList`). A Classic quick action list is also required for deploy (New Task, New Event, Log a Call). LWC actions cannot be placed in `quickActionList`.

## Post-deployment setup

1. Assign **FS Alert Center Component Access** to dispatchers (and to anyone who must create or see Alert Center data).
2. Add **FS Alert Center** (`fsAlertCenterUtility`) to the Lightning app **utility bar**.
3. Confirm Change Data Capture includes `FS_AlertCenter__c` (packaged as `FS_ChangeEvents_AlertCenter_ChangeEvent` on the ChangeEvents channel).
4. Set **Default Setting** CMDT flags for Priority Alerts / Panic Alerts / priorities.
5. Add **FS Mobile Panic Button** as a Field Service Mobile global action. The packaged publisher layout is **FS Mobile Global Layout**. In Setup → Publisher Layouts, assign it to the **Field Service Technician** profile (profile assignment is **not** in the package).
6. Prime `FS_AlertCenter__c`, `ServiceResource`, and `ServiceTerritoryMember` in the Field Service Mobile Offline Brief.
7. Ensure technicians have a **Service Resource** linked to their User and a **primary** Service Territory Member so panic rows get a territory and appear on dispatcher utilities.
8. Dispatchers must **load Gantt territories** or the utility stays empty.

Optional: set **FS Trigger Bypass Setting** at org, profile, or user level to skip the Service Appointment trigger during data loads.

## Packaged objects and automation (summary)

| API name | Type | Role |
|---|---|---|
| `FS_AlertCenter__c` | Custom object | Alert record (job or panic) |
| `FS_Alert_Dismissal__c` | Custom object | Per-user hide |
| `FS_Alert_Center_Setting__mdt` | Custom metadata | Feature flags and priorities |
| `FS_Trigger_Bypass_Setting__c` | Hierarchy custom setting | Skip SA trigger |
| `FS_ServiceAppointmentTrigger` | Trigger | Parent lookups + job alerts |
| `fsAlertCenterUtility` | LWC | Dispatcher utility |
| `fsMobilePanicButton` | LWC | Technician SOS |
| `FS_Mobile_Panic_Button` | Global quick action | Hosts the SOS LWC |
| `FS_AlertBuzzer` | Static resource | New-alert audio |

Source API version in `sfdx-project.json` is **61.0**.
