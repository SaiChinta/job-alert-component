/**
 * @description Controller for the High Priority Job Alerts Utility Bar LWC.
 * Handles fetching dynamic alerts, user workgroups, and processing global/local dismissals.
 * Enforces PMD compliance through SYSTEM_MODE database operations and proper sharing.
 */
@SuppressWarnings('PMD.ApexCRUDViolation, PMD.ExcessivePublicCount')
public inherited sharing class JobAlertUtilityController {
    
    /**
     * @description Helper to get Service Territories active on the user's FSL Gantt.
     * @param userId The ID of the current user.
     * @return List of Service Territory IDs.
     */
    private static List<Id> getActiveGanttTerritories(Id userId) {
        List<Id> territoryIds = new List<Id>();
        for (FSL__User_Setting_Territory__c ust : [
            SELECT FSL__Service_Territory__c 
            FROM FSL__User_Setting_Territory__c 
            WHERE FSL__User_Setting__r.FSL__User__c = :userId
            WITH SYSTEM_MODE
        ]) {
            territoryIds.add(ust.FSL__Service_Territory__c);
        }
        return territoryIds;
    }

/**
     * @description Retrieves all active, unacknowledged Job Alerts.
     * @param cacheBuster A dummy timestamp string passed from the LWC to prevent the 
     * browser from aggressively caching the polling network requests.
     * @return List of Job_Alert__c records with associated Service Appointment details.
     */
    @AuraEnabled
    public static List<Job_Alert__c> getActiveAlerts(String cacheBuster) {
        Id userId = UserInfo.getUserId();
        
        List<Id> activeTerritories = getActiveGanttTerritories(userId);
        if (activeTerritories.isEmpty()) {
            return new List<Job_Alert__c>();
        }
        
        // Query Job Alerts, enforcing SYSTEM_MODE for internal processing
        return [
            SELECT Id, Name, Status__c, CreatedDate,
                   Service_Appointment__c, 
                   Service_Appointment__r.AppointmentNumber, 
                   Service_Appointment__r.WorkOrderTask_Priority__c, 
                   Service_Appointment__r.EarliestStartTime,
                   Service_Appointment__r.DueDate,
                   Service_Appointment__r.Street, 
                   Service_Appointment__r.City,
                   Service_Appointment__r.Maintenance_Type__c,
                   Service_Territory__r.Name,
                   Service_Appointment__r.Ellipse_WorkOrderTask_Number__c
           FROM Job_Alert__c
            WHERE (Status__c = 'New' OR (Status__c = 'Acknowledged' AND LastModifiedById = :userId))
            AND Service_Territory__c IN :activeTerritories
            AND Id NOT IN (
                SELECT Job_Alert__c 
                FROM Alert_Dismissal__c 
                WHERE User__c = :userId
            )
            WITH SYSTEM_MODE
            ORDER BY Service_Appointment__r.WorkOrderTask_Priority__c, CreatedDate ASC
        ];
    }

    /**
     * @description Globally acknowledges an alert.
     * @param alertId The ID of the Job_Alert__c record.
     */
    @AuraEnabled
    public static void acknowledgeAlert(Id alertId) {
        update as system new Job_Alert__c(Id = alertId, Status__c = 'Acknowledged');
        // NEW: Notify other clients to refresh their UI - REPLACE CDC
        // EventBus.publish(new Job_Alert_Event__e(Job_Alert_Id__c = alertId, Change_Type__c = 'UPDATE'));
    }

    /**
     * @description Dismisses an alert locally for the current user. 
     * If the alert is Acknowledged, it reverts to 'New' to reappear globally.
     * @param alertId The ID of the Job_Alert__c record.
     */
    @AuraEnabled
    public static void dismissAlert(Id alertId) {
        Job_Alert__c alert = [SELECT Id, Status__c FROM Job_Alert__c WHERE Id = :alertId WITH SYSTEM_MODE LIMIT 1];
        
        if (alert.Status__c == 'Acknowledged') {
            // Revert back to New so CDC broadcasts it to everyone
            alert.Status__c = 'New';
            update as system alert;
            // NEW: Notify other clients that this reverted to 'New' - REPLACE CDC
            // EventBus.publish(new Job_Alert_Event__e(Job_Alert_Id__c = alertId, Change_Type__c = 'UPDATE'));
        } else {
            // Standard personal dismissal
            insert as system new Alert_Dismissal__c(Job_Alert__c = alertId, User__c = UserInfo.getUserId());
        }
    }

    /**
     * @description Bulk dismisses all currently visible alerts locally for the current user.
     * Reverts any 'Acknowledged' alerts back to 'New' globally.
     * @param alertIds List of Job_Alert__c IDs.
     */
    @AuraEnabled
    public static void dismissAllAlerts(List<Id> alertIds) {
        if (alertIds == null || alertIds.isEmpty()) {
            return;
        }

        List<Job_Alert__c> alertsToProcess = [SELECT Id, Status__c FROM Job_Alert__c WHERE Id IN :alertIds WITH SYSTEM_MODE];
        List<Alert_Dismissal__c> dismissalsToInsert = new List<Alert_Dismissal__c>();
        List<Job_Alert__c> alertsToRevert = new List<Job_Alert__c>();
        Id userId = UserInfo.getUserId();

        for (Job_Alert__c alert : alertsToProcess) {
            if (alert.Status__c == 'Acknowledged') {
                alert.Status__c = 'New';
                alertsToRevert.add(alert);
            } else {
                dismissalsToInsert.add(new Alert_Dismissal__c(Job_Alert__c = alert.Id, User__c = userId));
            }
        }

        if (!alertsToRevert.isEmpty()) {
            update as system alertsToRevert;
        }
        if (!dismissalsToInsert.isEmpty()) {
            insert as system dismissalsToInsert;
        }
    }

    /**
     * @description Dynamically creates a temporary Gantt filter for a specific Service Appointment.
     * @param saId The ID of the Service Appointment.
     * @param saNumber The SA Number for the filter name.
     * @return String Success or Error message.
     */
    @AuraEnabled
    public static String createTemporaryGanttFilter(Id saId, String saNumber) {
        try {
            List<String> saIdsList = new List<String>{ String.valueOf(saId) };
            
            FSL__CreateFilterEvent__e filterEvent = new FSL__CreateFilterEvent__e(
                FSL__ServiceApptIds__c = JSON.serialize(saIdsList),
                FSL__FilterName__c = saNumber + ' - Priority Alert',
                FSL__Description__c = 'Temporary filter for High Priority Alert',
                FSL__FilterCategory__c = 'GENERAL',
                FSL__LoadFilterImmediately__c = true 
            );
            
            Database.SaveResult sr = EventBus.publish(filterEvent);
            
            if (sr.isSuccess()) {
                return 'Success';
            } else {
                return 'Failed to publish Gantt filter event.';
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error creating Gantt filter: ' + e.getMessage());
        }
    }

    /**
     * @description Restores all dismissed alerts for the current user by deleting their personal dismissal records.
     */
    @AuraEnabled
    public static void undoAllDismissals() {
        try {
            Id userId = UserInfo.getUserId();
            List<Alert_Dismissal__c> dismissals = [
                SELECT Id 
                FROM Alert_Dismissal__c 
                WHERE User__c = :userId 
                AND CreatedDate = TODAY 
                WITH SYSTEM_MODE
            ];
            
            if (!dismissals.isEmpty()) {
                delete as system dismissals;
            }
        } catch (Exception e) {
            throw new AuraHandledException('Error restoring alerts: ' + e.getMessage());
        }
    }
}