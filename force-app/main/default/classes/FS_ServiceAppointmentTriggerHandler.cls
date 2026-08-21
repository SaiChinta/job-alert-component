/**
 * @description Trigger Handler for ServiceAppointment to populate work order lookups and create FS Alert Center records.
 */
public with sharing class FS_ServiceAppointmentTriggerHandler {

    /**
     * @description Main entry point for ServiceAppointment trigger routing.
     * @param newRecords The list of new records from trigger context.
     * @param oldMap Map of old records from trigger context.
     * @param operationType The current System.TriggerOperation value.
     */
    public static void handleTrigger(List<ServiceAppointment> newRecords, Map<Id, ServiceAppointment> oldMap, System.TriggerOperation operationType) {
        // Query custom setting bypass
        FS_Trigger_Bypass_Setting__c bypass = FS_Trigger_Bypass_Setting__c.getInstance();
        if (bypass != null && bypass.Bypass_Service_Appointment_Trigger__c) {
            return;
        }

        switch on operationType {
            when BEFORE_INSERT {
                populateParentFields(newRecords);
            }
            when BEFORE_UPDATE {
                populateParentFields(newRecords);
            }
            when AFTER_INSERT {
                createJobAlertsIfNeeded(newRecords, null);
            }
            when AFTER_UPDATE {
                createJobAlertsIfNeeded(newRecords, oldMap);
            }
        }
    }

    /**
     * @description Populates lookup relationships FS_Work_Order_Line_Item__c and FS_Work_Order__c before insert/update.
     * @param records The list of ServiceAppointment records to process.
     */
    private static void populateParentFields(List<ServiceAppointment> records) {
        Set<Id> woliIds = new Set<Id>();

        for (ServiceAppointment sa : records) {
            if (sa.ParentRecordId != null) {
                Id parentId = sa.ParentRecordId;
                if (parentId.getSObjectType() == WorkOrder.SObjectType) {
                    sa.FS_Work_Order__c = parentId;
                    sa.FS_Work_Order_Line_Item__c = null;
                } else if (parentId.getSObjectType() == WorkOrderLineItem.SObjectType) {
                    sa.FS_Work_Order_Line_Item__c = parentId;
                    woliIds.add(parentId);
                } else {
                    sa.FS_Work_Order__c = null;
                    sa.FS_Work_Order_Line_Item__c = null;
                }
            } else {
                sa.FS_Work_Order__c = null;
                sa.FS_Work_Order_Line_Item__c = null;
            }
        }

        if (!woliIds.isEmpty()) {
            Map<Id, WorkOrderLineItem> woliMap = new Map<Id, WorkOrderLineItem>([
                SELECT Id, WorkOrderId 
                FROM WorkOrderLineItem 
                WHERE Id IN :woliIds
                WITH SECURITY_ENFORCED
            ]);

            for (ServiceAppointment sa : records) {
                if (sa.FS_Work_Order_Line_Item__c != null && woliMap.containsKey(sa.FS_Work_Order_Line_Item__c)) {
                    sa.FS_Work_Order__c = woliMap.get(sa.FS_Work_Order_Line_Item__c).WorkOrderId;
                }
            }
        }
    }

    /**
     * @description Creates FS_AlertCenter__c records in after-trigger context based on Priority configured settings.
     * @param records List of ServiceAppointment records.
     * @param oldMap Map of old ServiceAppointment records.
     */
    private static void createJobAlertsIfNeeded(List<ServiceAppointment> records, Map<Id, ServiceAppointment> oldMap) {
        List<FS_Alert_Center_Setting__mdt> settings = [
            SELECT Alert_Priorities__c, Priority_Alerts_Enabled__c
            FROM FS_Alert_Center_Setting__mdt
            WHERE DeveloperName = 'Default_Setting'
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];

        if (settings.isEmpty()) {
            return;
        }

        FS_Alert_Center_Setting__mdt config = settings[0];
        if (!config.Priority_Alerts_Enabled__c) {
            return;
        }

        Set<String> targetPriorities = new Set<String>();
        if (String.isNotBlank(config.Alert_Priorities__c)) {
            for (String priority : config.Alert_Priorities__c.split(',')) {
                targetPriorities.add(priority.trim().toLowerCase());
            }
        }

        Set<Id> saIdsToProcess = new Set<Id>();
        for (ServiceAppointment sa : records) {
            Boolean hasChanged = (oldMap == null || 
                                  sa.FS_Work_Order_Line_Item__c != oldMap.get(sa.Id).FS_Work_Order_Line_Item__c ||
                                  sa.FS_Work_Order__c != oldMap.get(sa.Id).FS_Work_Order__c);
            if (hasChanged) {
                saIdsToProcess.add(sa.Id);
            }
        }

        if (saIdsToProcess.isEmpty()) {
            return;
        }

        List<ServiceAppointment> sasWithParents = [
            SELECT Id, ServiceTerritoryId, 
                   FS_Work_Order_Line_Item__r.Priority, 
                   FS_Work_Order__r.Priority
            FROM ServiceAppointment
            WHERE Id IN :saIdsToProcess
            WITH SECURITY_ENFORCED
        ];

        List<FS_AlertCenter__c> existingAlerts = [
            SELECT Service_Appointment__c
            FROM FS_AlertCenter__c
            WHERE Service_Appointment__c IN :saIdsToProcess
            WITH SECURITY_ENFORCED
        ];

        Set<Id> existingSaAlertIds = new Set<Id>();
        for (FS_AlertCenter__c alert : existingAlerts) {
            existingSaAlertIds.add(alert.Service_Appointment__c);
        }

        List<FS_AlertCenter__c> alertsToInsert = new List<FS_AlertCenter__c>();
        for (ServiceAppointment sa : sasWithParents) {
            if (existingSaAlertIds.contains(sa.Id)) {
                continue;
            }

            String computedPriority = null;
            if (sa.FS_Work_Order_Line_Item__r != null && sa.FS_Work_Order_Line_Item__r.Priority != null) {
                computedPriority = sa.FS_Work_Order_Line_Item__r.Priority;
            } else if (sa.FS_Work_Order__r != null && sa.FS_Work_Order__r.Priority != null) {
                computedPriority = sa.FS_Work_Order__r.Priority;
            }

            if (computedPriority != null && targetPriorities.contains(computedPriority.toLowerCase())) {
                alertsToInsert.add(new FS_AlertCenter__c(
                    Service_Appointment__c = sa.Id,
                    Service_Territory__c = sa.ServiceTerritoryId,
                    Status__c = 'New',
                    Alert_Type__c = 'High Priority Alert'
                ));
            }
        }

        if (!alertsToInsert.isEmpty()) {
            insert as system alertsToInsert;
        }
    }
}
