# New-org implementation checklist

This file is the **manual work after a metadata deploy**. Product behaviour and architecture are in `README.md` and `docs/FS_Alert_Center_Design.md`. Deploy inventory is `manifest/package.xml`.

A deploy does **not** assign permission sets, add the utility bar, assign the mobile publisher layout, set profile record-type defaults, prime the Offline Brief, or convert existing Service Appointments. Those steps are below.

Do not skip the prerequisites. Field Service objects and events this package depends on are **not** created by this repository.

## 1. Prerequisites (before deploy)

Confirm all of the following in the target org:

1. **Field Service** is enabled and licensed (dispatcher and technician users exist or can be created).
2. These platform objects/events already exist: `ServiceAppointment`, `ServiceResource`, `ServiceTerritory`, `ServiceTerritoryMember`, `WorkOrder`, `WorkOrderLineItem`, `FSL__User_Setting_Territory__c`, `FSL__InJeopardy__c` on Service Appointment, `FSL__CreateFilterEvent__e`.
3. Dispatchers use a **Lightning Field Service** app with a **Gantt** (territory load is how the utility filters alerts).
4. Technicians use **Field Service Mobile**.
5. Salesforce CLI is authorized to the target org. Source API version is **61.0** (`sfdx-project.json`).
6. You have a **full local copy** of the project (`sfdx-project.json`, `force-app/`, `manifest/package.xml`). Do not deploy from an online-only Drive placeholder.

If another Service Appointment trigger framework (for example Trigger Actions Framework) already runs in the org, read **step 12** before you deploy, so the handler is not registered twice.

## 2. Deploy the package

From the project root:

```bash
sf project deploy start --manifest manifest/package.xml --target-org <TARGET_ORG_ALIAS>
```

If source tracking reports conflicts:

```bash
sf project deploy start --manifest manifest/package.xml --target-org <TARGET_ORG_ALIAS> --ignore-conflicts
```

Wait until the deploy succeeds. The first deploy of `FS_Alert_Center_Dispatcher` requires **Edit** on `FS_Alert_Dismissal__c` whenever **Delete** is granted; that is already set in source.

## 3. Assign permission sets

Assign **one or more** of these (they are not license-locked). Assignment is not packaged.

| Permission set | API name | Who |
|---|---|---|
| FS Alert Center Dispatcher | `FS_Alert_Center_Dispatcher` | Schedulers and team leaders who use the utility |
| FS Alert Center Field Resource | `FS_Alert_Center_Field_Resource` | Technicians who raise Panic Alerts |
| FS Alert Center Appointment Booking | `FS_Alert_Center_Appointment_Booking` | External or Experience Cloud booking users who save Field Services appointments |

Setup path: **Setup → Permission Sets → [name] → Manage Assignments**.

Notes:

- The booking set grants **Field Services** record type **visibility** only. It does not set the profile default (step 4).
- Dispatcher object access is **not** View All. The **utility** queries Alert Center in system mode and filters by Gantt territories. **List views and record pages** still follow org-wide default **Private** plus sharing (step 11).
- If you are upgrading an org that still has **FS Alert Center Component Access**, assign the three new sets, confirm behaviour, then unassign and delete the old set. A new org will not have that old set.

## 4. Field Services record type on profiles

Automation runs **only** for Service Appointment record type **Field Services** (`Field_Services`). Other record types skip parent-lookup population and alert inserts.

1. Setup → **Profiles** (or the permission set group you use for Field Service users) → Object Settings → **Service Appointments**.
2. Enable record type **Field Services**.
3. Set **Field Services** as the **default** for users who create appointments from the Gantt or mobile.

The booking permission set does **not** replace this profile default.

Existing appointments keep their current record type. There is **no packaged conversion job**. Appointments that must generate alerts have to be updated to Field Services (manually or with your own data job).

## 5. Dispatcher Lightning app: utility bar and tabs

### Utility bar

1. Open the Lightning app dispatchers actually use (typically the Field Service dispatcher console).
2. **Edit App** → **Utility Items**.
3. Add **FS Alert Center** (`fsAlertCenterUtility`).
4. Save and activate.

The Salesforce utility item label becomes `Alert Center` or `Alert Center (n)`. Do not expect a second inner title with the same count.

### Tabs (optional but needed for audit list views)

1. Same app → **Navigation Items**.
2. Add **FS Alert Centers** and **FS Alert Dismissals** if dispatchers or admins should open packaged list views.

Lightning record pages `FS_AlertCenter_Record_Page` and `FS_Alert_Dismissal_Record_Page` are packaged as the object View overrides. Confirm they activate after deploy (Lightning App Builder → Activation) if View still opens the default layout.

## 6. Change Data Capture

The package includes channel member `FS_ChangeEvents_AlertCenter_ChangeEvent` (`FS_AlertCenter__ChangeEvent` on the **ChangeEvents** channel).

1. Setup → **Change Data Capture**.
2. Confirm **FS Alert Center** is selected.

Lightning utility updates use empApi on `/data/FS_AlertCenter__ChangeEvent`. If CDC is off, CREATE/UPDATE will not refresh the utility in real time (Experience Cloud uses polling instead; see step 13).

## 7. Custom metadata: Default Setting

Setup → **Custom Metadata Types** → **FS Alert Center Setting** → **Default Setting**.

Packaged defaults:

| Field | Packaged value | What you must decide |
|---|---|---|
| Priority Alerts Enabled | true | Leave on to create High Priority Alerts and show the Priority tab |
| Panic Alerts Enabled | true | Dispatcher **UI** only. Off hides Panic in the utility; mobile SOS can still insert records |
| Cancellation Alerts Enabled | **false** | Turn **on** only if you want Cancellation Alerts when a Field Service Mobile licensed user sets Status to `Canceled` |
| Jeopardy Alerts Enabled | **false** | Turn **on** only if you want In Jeopardy Alerts when `FSL__InJeopardy__c` becomes true |
| Alert Priorities | `High,Critical,Jeopardy` | Comma-separated, case-insensitive match to **Work Order Line Item Priority**, then **Work Order Priority** |

After changing flags, hard-refresh the utility so tabs match.

`Jeopardy` in Alert Priorities is a **WO/WOLI priority token**. It is not the Field Service **In Jeopardy** checkbox. Those are separate features.

## 8. Nature of the Emergency picklist

The field `FS_AlertCenter__c.Nature_of_the_Emergency__c` is a **restricted** picklist. The SOS combobox loads **active** values from schema (`getObjectInfo` + `getPicklistValues`). If schema cannot be read (offline without priming, or a wire error), the LWC falls back to four packaged labels: Medical crisis, Physical assault, Threat of violence, Environmental accident.

Those fallback values are **inactive** in the packaged field XML. Selecting a fallback value on a restricted picklist **fails** `createRecord`.

In a new org, after deploy:

1. Setup → Object Manager → **FS Alert Center** → Fields → **Nature of the Emergency**.
2. Activate, deactivate, or add values to match the business (API name must equal what SOS will store).
3. Keep at least the values technicians are allowed to save as **active**.
4. Do not rely on the four fallback values unless you also **reactivate** them on the field.

The packaged active value may include an org-specific label from the source org. Replace it if it does not apply.

## 9. Field Service Mobile: publisher layout and Offline Brief

### Publisher layout (required for the SOS action)

The package deploys global publisher layout **FS Mobile Global Layout** with **FS Mobile Panic Button** (`FS_Mobile_Panic_Button`) in Mobile and Lightning Actions.

**Profile assignment is not packaged.**

1. Setup → **Publisher Layouts**.
2. Assign **FS Mobile Global Layout** to the **Field Service Technician** profile (and any other technician profile that should see SOS).
3. If a profile uses a **different** publisher layout, add **FS Mobile Panic Button** to that layout as well.

The permission set does not place the global action on the layout.

If this org already had a layout with the same name, `--ignore-conflicts` overwrites it with the packaged action list. Review that layout after deploy.

### Offline Brief (required for offline SOS and schema picklists)

In Field Service Mobile settings, prime at least:

- `FS_AlertCenter__c` (createRecord **and** Nature picklist values)
- `ServiceResource`
- `ServiceTerritoryMember`

Without priming, online SOS can still work; offline SOS and schema-driven Nature options will not. Unprimed picklist wires fall back to the four packaged values (see step 8).

### Device

Technicians must allow **location** when SOS requests GPS (high accuracy, 10 second timeout).

## 10. Technician and dispatcher master data

### Technicians (Panic Alerts)

For each technician who will tap SOS:

1. A **Service Resource** whose `RelatedRecordId` is that User. SOS fails with an error if none exists.
2. A **Service Territory Member** with Territory Type **Primary** (`P` or `Primary`). That territory is stored on the alert.
3. Optional for the panic **card**: User **Phone** and **Employee Number** (shown only when populated).

A Panic Alert **without** `Service_Territory__c` is stored but **never shown** in the utility.

### Dispatchers (utility not empty)

1. Open Field Service **Gantt**.
2. **Load** the Service Territories that should receive alerts.
3. Open Alert Center. If no territories are loaded, the list is empty by design.
4. After changing Gantt territories, use **Sync** on the type toolbar.

Matching is exact on `FS_AlertCenter__c.Service_Territory__c`. Parent/child territory trees are not expanded unless those territories are also loaded.

## 11. Sharing and list views

Org-wide default for `FS_AlertCenter__c` is **Private**. `FS_Alert_Dismissal__c` is **Controlled by Parent**.

- **Utility:** system-mode queries; dispatchers see alerts for **loaded Gantt territories** without each alert being shared to them.
- **Tabs / list views / record pages:** the running user must have sharing (or a higher access model you choose). If auditors need list views, add sharing rules, ownership, or a permission set with View All — that last option is **not** packaged.

Packaged list views (not Gantt-filtered): FS All Alert Centers, All High Priority Alerts, All Panic Alerts, All Cancellation Alerts, All In Jeopardy Alerts, plus All.

## 12. Service Appointment trigger vs Trigger Actions Framework

This package deploys `FS_ServiceAppointmentTrigger`, which calls `FS_ServiceAppointmentTriggerHandler`. It does **not** register that handler in TAF.

- **Keep the packaged trigger** (recommended for this package): do **not** also add the handler as a Trigger Action, or it runs twice.
- **Use TAF instead:** in that org only, empty the packaged trigger body and register the handler in TAF. Do not leave both active.

Optional: hierarchy custom setting **FS Trigger Bypass Setting** → `Bypass_Service_Appointment_Trigger__c`. Set at org, profile, or user for data loads. Leave it **unchecked** for users who should generate alerts.

## 13. Experience Cloud (optional)

`fsAlertCenterUtility` can be placed on an Experience Cloud page.

1. Set component property **`isCommunityMode`** to true (polling every 20 seconds; empApi is not used).
2. Assign **FS Alert Center Dispatcher** (or equivalent Apex + object access) to community users who should see the panel.
3. Booking-only users get **FS Alert Center Appointment Booking** only; they do not need the utility.

## 14. Work Order / appointment data that the trigger expects

High Priority Alerts:

1. Appointment record type is **Field Services**.
2. `FS_Work_Order__c` and/or `FS_Work_Order_Line_Item__c` are populated (the trigger fills them from `ParentRecordId` **only when blank**).
3. WOLI Priority, else WO Priority, is in `Alert_Priorities__c`.
4. Alert is created on **insert** or when those **parent lookups change**, not when only WO priority is edited later.
5. One High Priority Alert per Service Appointment.

The job **card** shows `ServiceAppointment.Priority__c`. Creation uses WO/WOLI Priority. Keep those aligned if the card must match the trigger.

Cancellation Alerts (after you enable the CMDT flag):

- Status API value must be **`Canceled`** (packaged Field Services record type includes that value). If the org renamed Status, either restore `Canceled` or the feature will not fire.
- The user who cancels must have the **Field Service Mobile** permission set license. A dispatcher cancel from the console does not create this alert.

In Jeopardy Alerts (after you enable the CMDT flag):

- Set Field Service **In Jeopardy** (`FSL__InJeopardy__c`) to true. Do not confuse this with WO priority `Jeopardy`.

## 15. Smoke test in the new org

Do this after the steps above. Hard-refresh Lightning (and Field Service Mobile) so LWCs load.

1. **Priority:** Create or update a Field Services appointment with WO/WOLI priority `High` (or another token in Default Setting). Confirm an `FS_AlertCenter__c` with Alert Type **High Priority Alert**. Dispatcher with that territory on the Gantt sees it on the Priority tab. **Today only** starts checked.
2. **Panic:** Technician with Service Resource + primary territory opens **Panic Button**, selects an **active** Nature value (or leaves it blank), taps SOS, allows GPS. Record saves. Dispatcher Panic tab shows Nature when populated; map pin when GPS exists.
3. **Restricted picklist:** Confirm the combobox lists **active** Nature values, not only the four inactive fallbacks.
4. **Cancellation (if enabled):** As a user with the **Field Service Mobile** permission set license, change Status to `Canceled`. Expect one Cancellation Alert, the Cancellation tab, and **All Cancellation Alerts**. Cancel the same way as a dispatcher **without** that license — no Cancellation Alert.
5. **In Jeopardy (if enabled):** Set In Jeopardy true. One In Jeopardy Alert; **All In Jeopardy Alerts** list view.
6. **Uniqueness:** Repeat cancel or jeopardy on the same appointment; a second row of that type must not be created.
7. **Acknowledge / dismiss / Undo / Dismiss All:** Per-tab; Undo restores **today’s** dismissals for **that type** only.
8. **Gantt filter** on a job card: a temporary Gantt filter for that Service Appointment loads.
9. **Buzzer / badge:** A new relevant alert highlights the utility item and plays `FS_AlertBuzzer` (allow audio in the browser).

## 16. What you should not expect the package to do

- Assign permission sets, publisher layouts, or Lightning apps.
- Set Service Appointment record type **defaults** on profiles.
- Convert historical appointments to Field Services.
- Enable Cancellation or In Jeopardy (both default **off**).
- Share Private Alert Center records for list views.
- Expand Gantt parent territories automatically.
- Disable mobile SOS when Panic is turned off in CMDT.
- Register (or unregister) Trigger Actions Framework.

When this checklist is complete, day-to-day behaviour matches `README.md`.
