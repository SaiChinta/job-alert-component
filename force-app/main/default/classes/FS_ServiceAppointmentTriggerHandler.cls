/**
 * @description Trigger Handler for ServiceAppointment to populate work order lookups and create FS Alert Center records.
 */
public with sharing class FS_ServiceAppointmentTriggerHandler {

    private static final String SA_RECORD_TYPE_DEV_NAME = 'Field_Services';
    private static final String ALERT_TYPE_PRIORITY = 'High Priority Alert';
    private static final String ALERT_TYPE_CANCELLATION = 'Cancellation Alert';
    private static final String ALERT_TYPE_JEOPARDY = 'In Jeopardy Alert';
    private static final String STATUS_CANCELED = 'Canceled';
    private static final Set<String> FIELD_SERVICE_MOBILE_PSL_DEV_NAMES = new Set<String>{
        'FieldServiceMobilePsl',
        'FieldServiceMobile'
    };
    private static final String FIELD_SERVICE_MOBILE_PSL_LABEL = 'Field Service Mobile';

    /**
     * @description Test-only CMDT override so tests do not depend on org Default_Setting toggles.
     */
    @TestVisible
    private static FS_Alert_Center_Setting__mdt settingsOverride;

    /**
     * @description Test-only Field Service Mobile PSL override. Null uses the running user's assignment.
     */
    @TestVisible
    private static Boolean fieldServiceMobileLicenseOverride;

    private static Boolean fieldServiceMobileLicenseChecked;
    private static Boolean runningUserHasMobilePsl;

    /**
     * @description Main entry point for ServiceAppointment trigger routing.
     * @param newRecords The list of new records from trigger context.
     * @param oldMap Map of old records from trigger context.
     * @param operationType The current System.TriggerOperation value.
     */
    public static void handleTrigger(List<ServiceAppointment> newRecords, Map<Id, ServiceAppointment> oldMap, System.TriggerOperation operationType) {
        FS_Trigger_Bypass_Setting__c bypass = FS_Trigger_Bypass_Setting__c.getInstance();
        if (bypass != null && bypass.Bypass_Service_Appointment_Trigger__c) {
            return;
        }

        List<ServiceAppointment> scopedRecords = filterFieldServicesAppointments(newRecords);
        if (scopedRecords.isEmpty()) {
            return;
        }

        switch on operationType {
            when BEFORE_INSERT {
                populateParentFields(scopedRecords);
            }
            when BEFORE_UPDATE {
                populateParentFields(scopedRecords);
            }
            when AFTER_INSERT {
                createAlertsIfNeeded(scopedRecords, null);
            }
            when AFTER_UPDATE {
                createAlertsIfNeeded(scopedRecords, oldMap);
            }
        }
    }

    /**
     * @description Returns the Field Services record type Id for Service Appointment, or null if it is not in the org.
     * @return The Field_Services record type Id, or null.
     */
    private static Id getFieldServicesRecordTypeId() {
        Schema.RecordTypeInfo info = Schema.SObjectType.ServiceAppointment.getRecordTypeInfosByDeveloperName()
            .get(SA_RECORD_TYPE_DEV_NAME);
        if (info == null) {
            return null;
        }
        return info.getRecordTypeId();
    }

    /**
     * @description Keeps only Service Appointments whose record type is Field Services.
     * @param records Trigger new records.
     * @return Appointments that use the Field_Services record type.
     */
    private static List<ServiceAppointment> filterFieldServicesAppointments(List<ServiceAppointment> records) {
        List<ServiceAppointment> scoped = new List<ServiceAppointment>();
        Id fieldServicesRtId = getFieldServicesRecordTypeId();
        if (fieldServicesRtId == null || records == null) {
            return scoped;
        }
        for (ServiceAppointment sa : records) {
            if (sa.RecordTypeId == fieldServicesRtId) {
                scoped.add(sa);
            }
        }
        return scoped;
    }

    /**
     * @description Returns Default_Setting CMDT, or a test override when set.
     * @return The setting record, or null if none exists.
     */
    @TestVisible
    private static FS_Alert_Center_Setting__mdt getDefaultSetting() {
        if (settingsOverride != null) {
            return settingsOverride;
        }
        List<FS_Alert_Center_Setting__mdt> settings = [
            SELECT Alert_Priorities__c, Priority_Alerts_Enabled__c, Cancellation_Alerts_Enabled__c,
                   Jeopardy_Alerts_Enabled__c
            FROM FS_Alert_Center_Setting__mdt
            WHERE DeveloperName = 'Default_Setting'
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        if (settings.isEmpty()) {
            return null;
        }
        return settings[0];
    }

    /**
     * @description Populates blank FS_Work_Order_Line_Item__c and FS_Work_Order__c lookups from ParentRecordId.
     * Existing lookup values are left unchanged.
     * @param records The list of ServiceAppointment records to process.
     */
    private static void populateParentFields(List<ServiceAppointment> records) {
        Set<Id> woliIds = new Set<Id>();
        for (ServiceAppointment sa : records) {
            collectBlankParentLookups(sa, woliIds);
        }
        if (woliIds.isEmpty()) {
            return;
        }

        Map<Id, WorkOrderLineItem> woliMap = new Map<Id, WorkOrderLineItem>([
            SELECT Id, WorkOrderId
            FROM WorkOrderLineItem
            WHERE Id IN :woliIds
            WITH SYSTEM_MODE
        ]);

        for (ServiceAppointment sa : records) {
            if (sa.FS_Work_Order__c != null || sa.FS_Work_Order_Line_Item__c == null) {
                continue;
            }
            WorkOrderLineItem woli = woliMap.get(sa.FS_Work_Order_Line_Item__c);
            if (woli != null) {
                sa.FS_Work_Order__c = woli.WorkOrderId;
            }
        }
    }

    /**
     * @description Fills blank parent lookups from ParentRecordId and collects WOLI Ids that still need a Work Order.
     * @param sa The Service Appointment being processed.
     * @param woliIds Collector for Work Order Line Item Ids.
     */
    private static void collectBlankParentLookups(ServiceAppointment sa, Set<Id> woliIds) {
        if (sa.ParentRecordId == null) {
            return;
        }
        Id parentId = sa.ParentRecordId;
        if (parentId.getSObjectType() == WorkOrder.SObjectType) {
            if (sa.FS_Work_Order__c == null) {
                sa.FS_Work_Order__c = parentId;
            }
            return;
        }
        if (parentId.getSObjectType() != WorkOrderLineItem.SObjectType) {
            return;
        }
        if (sa.FS_Work_Order_Line_Item__c == null) {
            sa.FS_Work_Order_Line_Item__c = parentId;
        }
        if (sa.FS_Work_Order__c == null && sa.FS_Work_Order_Line_Item__c != null) {
            woliIds.add(sa.FS_Work_Order_Line_Item__c);
        }
    }

    /**
     * @description Creates FS_AlertCenter__c rows for enabled priority, cancellation, and in-jeopardy conditions.
     * @param records List of ServiceAppointment records.
     * @param oldMap Map of old ServiceAppointment records.
     */
    private static void createAlertsIfNeeded(List<ServiceAppointment> records, Map<Id, ServiceAppointment> oldMap) {
        FS_Alert_Center_Setting__mdt config = getDefaultSetting();
        if (config == null) {
            return;
        }

        Map<Id, Set<String>> existingTypesBySa = loadExistingAlertTypes(records);
        List<FS_AlertCenter__c> alertsToInsert = new List<FS_AlertCenter__c>();
        addPriorityAlerts(records, oldMap, config, existingTypesBySa, alertsToInsert);
        addCancellationAlerts(records, oldMap, config, existingTypesBySa, alertsToInsert);
        addJeopardyAlerts(records, oldMap, config, existingTypesBySa, alertsToInsert);

        if (!alertsToInsert.isEmpty()) {
            insert as system alertsToInsert;
        }
    }

    /**
     * @description Loads existing Alert Center types keyed by Service Appointment Id.
     * @param records Service Appointments in the trigger.
     * @return Map of appointment Id to existing alert type API values.
     */
    private static Map<Id, Set<String>> loadExistingAlertTypes(List<ServiceAppointment> records) {
        Map<Id, Set<String>> existingTypesBySa = new Map<Id, Set<String>>();
        Set<Id> saIds = new Set<Id>();
        for (ServiceAppointment sa : records) {
            if (sa.Id != null) {
                saIds.add(sa.Id);
            }
        }
        if (saIds.isEmpty()) {
            return existingTypesBySa;
        }

        for (FS_AlertCenter__c alert : [
            SELECT Service_Appointment__c, Alert_Type__c
            FROM FS_AlertCenter__c
            WHERE Service_Appointment__c IN :saIds
            WITH SYSTEM_MODE
        ]) {
            if (!existingTypesBySa.containsKey(alert.Service_Appointment__c)) {
                existingTypesBySa.put(alert.Service_Appointment__c, new Set<String>());
            }
            existingTypesBySa.get(alert.Service_Appointment__c).add(alert.Alert_Type__c);
        }
        return existingTypesBySa;
    }

    /**
     * @description Adds High Priority Alerts when parent lookups change and parent priority matches CMDT.
     * @param records Trigger new records.
     * @param oldMap Trigger old map, or null on insert.
     * @param config Default Setting CMDT.
     * @param existingTypesBySa Existing alert types by appointment.
     * @param alertsToInsert Collector for rows to insert.
     */
    private static void addPriorityAlerts(
        List<ServiceAppointment> records,
        Map<Id, ServiceAppointment> oldMap,
        FS_Alert_Center_Setting__mdt config,
        Map<Id, Set<String>> existingTypesBySa,
        List<FS_AlertCenter__c> alertsToInsert
    ) {
        if (config.Priority_Alerts_Enabled__c != true) {
            return;
        }

        Set<Id> saIdsToProcess = new Set<Id>();
        for (ServiceAppointment sa : records) {
            if (hasParentLookupChanged(sa, oldMap) && !alreadyHasType(existingTypesBySa, sa.Id, ALERT_TYPE_PRIORITY)) {
                saIdsToProcess.add(sa.Id);
            }
        }
        if (saIdsToProcess.isEmpty()) {
            return;
        }

        Set<String> targetPriorities = parsePriorityTokens(config.Alert_Priorities__c);
        Map<Id, ServiceAppointment> sasWithParents = new Map<Id, ServiceAppointment>([
            SELECT Id, ServiceTerritoryId,
                   FS_Work_Order_Line_Item__r.Priority,
                   FS_Work_Order__r.Priority
            FROM ServiceAppointment
            WHERE Id IN :saIdsToProcess
            WITH SYSTEM_MODE
        ]);

        for (Id saId : saIdsToProcess) {
            ServiceAppointment sa = sasWithParents.get(saId);
            if (sa == null) {
                continue;
            }
            String computedPriority = resolveParentPriority(sa);
            if (computedPriority != null && targetPriorities.contains(computedPriority.toLowerCase())) {
                registerAlert(existingTypesBySa, alertsToInsert, sa.Id, sa.ServiceTerritoryId, ALERT_TYPE_PRIORITY);
            }
        }
    }

    /**
     * @description Adds Cancellation Alerts when Status becomes Canceled by a Field Service Mobile licensed user.
     * @param records Trigger new records.
     * @param oldMap Trigger old map, or null on insert.
     * @param config Default Setting CMDT.
     * @param existingTypesBySa Existing alert types by appointment.
     * @param alertsToInsert Collector for rows to insert.
     */
    private static void addCancellationAlerts(
        List<ServiceAppointment> records,
        Map<Id, ServiceAppointment> oldMap,
        FS_Alert_Center_Setting__mdt config,
        Map<Id, Set<String>> existingTypesBySa,
        List<FS_AlertCenter__c> alertsToInsert
    ) {
        if (config.Cancellation_Alerts_Enabled__c != true) {
            return;
        }
        for (ServiceAppointment sa : records) {
            if (!becameCanceled(sa, oldMap)) {
                continue;
            }
            if (alreadyHasType(existingTypesBySa, sa.Id, ALERT_TYPE_CANCELLATION)) {
                continue;
            }
            registerAlert(existingTypesBySa, alertsToInsert, sa.Id, sa.ServiceTerritoryId, ALERT_TYPE_CANCELLATION);
        }
    }

    /**
     * @description Adds In Jeopardy Alerts when FSL__InJeopardy__c is or becomes true.
     * @param records Trigger new records.
     * @param oldMap Trigger old map, or null on insert.
     * @param config Default Setting CMDT.
     * @param existingTypesBySa Existing alert types by appointment.
     * @param alertsToInsert Collector for rows to insert.
     */
    private static void addJeopardyAlerts(
        List<ServiceAppointment> records,
        Map<Id, ServiceAppointment> oldMap,
        FS_Alert_Center_Setting__mdt config,
        Map<Id, Set<String>> existingTypesBySa,
        List<FS_AlertCenter__c> alertsToInsert
    ) {
        if (config.Jeopardy_Alerts_Enabled__c != true) {
            return;
        }
        for (ServiceAppointment sa : records) {
            if (!becameInJeopardy(sa, oldMap)) {
                continue;
            }
            if (alreadyHasType(existingTypesBySa, sa.Id, ALERT_TYPE_JEOPARDY)) {
                continue;
            }
            registerAlert(existingTypesBySa, alertsToInsert, sa.Id, sa.ServiceTerritoryId, ALERT_TYPE_JEOPARDY);
        }
    }

    /**
     * @description True when parent Work Order or WOLI lookups changed, including insert.
     * @param sa Trigger new appointment.
     * @param oldMap Trigger old map, or null on insert.
     * @return True if lookups should be evaluated for a High Priority Alert.
     */
    private static Boolean hasParentLookupChanged(ServiceAppointment sa, Map<Id, ServiceAppointment> oldMap) {
        if (oldMap == null || !oldMap.containsKey(sa.Id)) {
            return true;
        }
        ServiceAppointment oldSa = oldMap.get(sa.Id);
        return sa.FS_Work_Order_Line_Item__c != oldSa.FS_Work_Order_Line_Item__c
            || sa.FS_Work_Order__c != oldSa.FS_Work_Order__c;
    }

    /**
     * @description True when Status is Canceled on insert, or newly Canceled on update,
     * and the running user has the Field Service Mobile permission set license.
     * @param sa Trigger new appointment.
     * @param oldMap Trigger old map, or null on insert.
     * @return True if a Cancellation Alert should be considered.
     */
    private static Boolean becameCanceled(ServiceAppointment sa, Map<Id, ServiceAppointment> oldMap) {
        if (sa.Status != STATUS_CANCELED) {
            return false;
        }
        if (!runningUserHasFieldServiceMobileLicense()) {
            return false;
        }
        if (oldMap == null || !oldMap.containsKey(sa.Id)) {
            return true;
        }
        return oldMap.get(sa.Id).Status != STATUS_CANCELED;
    }

    /**
     * @description True when the running user is assigned the Field Service Mobile permission set license.
     * Cached for the transaction. Tests may override via fieldServiceMobileLicenseOverride.
     * @return True if the running user is a Field Service Mobile licensed field resource.
     */
    private static Boolean runningUserHasFieldServiceMobileLicense() {
        if (fieldServiceMobileLicenseOverride != null) {
            return fieldServiceMobileLicenseOverride;
        }
        if (fieldServiceMobileLicenseChecked == true) {
            return runningUserHasMobilePsl == true;
        }
        fieldServiceMobileLicenseChecked = true;
        List<PermissionSetLicenseAssign> assignments = [
            SELECT Id
            FROM PermissionSetLicenseAssign
            WHERE AssigneeId = :UserInfo.getUserId()
            AND (
                PermissionSetLicense.DeveloperName IN :FIELD_SERVICE_MOBILE_PSL_DEV_NAMES
                OR PermissionSetLicense.MasterLabel = :FIELD_SERVICE_MOBILE_PSL_LABEL
            )
            WITH SYSTEM_MODE
            LIMIT 1
        ];
        runningUserHasMobilePsl = !assignments.isEmpty();
        return runningUserHasMobilePsl;
    }

    /**
     * @description True when In Jeopardy is true on insert, or newly true on update.
     * @param sa Trigger new appointment.
     * @param oldMap Trigger old map, or null on insert.
     * @return True if an In Jeopardy Alert should be considered.
     */
    private static Boolean becameInJeopardy(ServiceAppointment sa, Map<Id, ServiceAppointment> oldMap) {
        if (sa.FSL__InJeopardy__c != true) {
            return false;
        }
        if (oldMap == null || !oldMap.containsKey(sa.Id)) {
            return true;
        }
        return oldMap.get(sa.Id).FSL__InJeopardy__c != true;
    }

    /**
     * @description Parses the CMDT comma-separated priority list to lowercase tokens.
     * @param rawPriorities CMDT Alert_Priorities__c value.
     * @return Set of lowercase priority tokens.
     */
    private static Set<String> parsePriorityTokens(String rawPriorities) {
        Set<String> targetPriorities = new Set<String>();
        if (String.isBlank(rawPriorities)) {
            return targetPriorities;
        }
        for (String priority : rawPriorities.split(',')) {
            targetPriorities.add(priority.trim().toLowerCase());
        }
        return targetPriorities;
    }

    /**
     * @description Resolves Work Order Line Item priority, then Work Order priority.
     * @param sa Appointment queried with parent priority fields.
     * @return Priority string, or null.
     */
    private static String resolveParentPriority(ServiceAppointment sa) {
        if (sa.FS_Work_Order_Line_Item__r != null && sa.FS_Work_Order_Line_Item__r.Priority != null) {
            return sa.FS_Work_Order_Line_Item__r.Priority;
        }
        if (sa.FS_Work_Order__r != null && sa.FS_Work_Order__r.Priority != null) {
            return sa.FS_Work_Order__r.Priority;
        }
        return null;
    }

    /**
     * @description True when this appointment already has the given alert type.
     * @param existingTypesBySa Existing types by appointment Id.
     * @param saId Service Appointment Id.
     * @param alertType Alert type API value.
     * @return True if the type already exists.
     */
    private static Boolean alreadyHasType(Map<Id, Set<String>> existingTypesBySa, Id saId, String alertType) {
        Set<String> types = existingTypesBySa.get(saId);
        return types != null && types.contains(alertType);
    }

    /**
     * @description Records a pending alert insert and marks the type as present for this transaction.
     * @param existingTypesBySa Existing types by appointment Id.
     * @param alertsToInsert Collector for rows to insert.
     * @param saId Service Appointment Id.
     * @param territoryId Service Territory Id.
     * @param alertType Alert type API value.
     */
    private static void registerAlert(
        Map<Id, Set<String>> existingTypesBySa,
        List<FS_AlertCenter__c> alertsToInsert,
        Id saId,
        Id territoryId,
        String alertType
    ) {
        if (!existingTypesBySa.containsKey(saId)) {
            existingTypesBySa.put(saId, new Set<String>());
        }
        existingTypesBySa.get(saId).add(alertType);
        alertsToInsert.add(new FS_AlertCenter__c(
            Service_Appointment__c = saId,
            Service_Territory__c = territoryId,
            Status__c = 'New',
            Alert_Type__c = alertType
        ));
    }
}
