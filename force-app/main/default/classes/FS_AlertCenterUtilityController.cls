/**
 * @description Controller for the Alert Center Utility Bar LWC.
 * Handles fetching alerts, CMDT display settings, dismissals, and Gantt filters.
 */
@SuppressWarnings('PMD.ApexCRUDViolation, PMD.ExcessivePublicCount')
public inherited sharing class FS_AlertCenterUtilityController {

    /**
     * @description Wrapper for Alert Center CMDT flags consumed by the utility LWC.
     */
    public class AlertCenterSettings {
        /**
         * @description True when Service Appointment priority alerts should be shown.
         */
        @AuraEnabled
        public Boolean priorityAlertsEnabled { get; set; }

        /**
         * @description True when Service Resource panic alerts should be shown.
         */
        @AuraEnabled
        public Boolean panicAlertsEnabled { get; set; }
    }

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
     * @description Returns CMDT flags that control which Alert Center tabs are visible.
     * @return AlertCenterSettings with priority and panic enablement flags.
     */
    @AuraEnabled(cacheable=true)
    public static AlertCenterSettings getAlertCenterSettings() {
        AlertCenterSettings result = new AlertCenterSettings();
        result.priorityAlertsEnabled = false;
        result.panicAlertsEnabled = false;

        List<FS_Alert_Center_Setting__mdt> settings = [
            SELECT Priority_Alerts_Enabled__c, Panic_Alerts_Enabled__c
            FROM FS_Alert_Center_Setting__mdt
            WHERE DeveloperName = 'Default_Setting'
            WITH SECURITY_ENFORCED
            LIMIT 1
        ];

        if (!settings.isEmpty()) {
            result.priorityAlertsEnabled = settings[0].Priority_Alerts_Enabled__c;
            result.panicAlertsEnabled = settings[0].Panic_Alerts_Enabled__c;
        }
        return result;
    }

    /**
     * @description Retrieves all active, undismissed Alert Center records for the user's Gantt territories.
     * @param cacheBuster A dummy timestamp string passed from the LWC to prevent browser caching.
     * @return List of FS_AlertCenter__c records with related appointment and resource details.
     */
    @AuraEnabled
    public static List<FS_AlertCenter__c> getActiveAlerts(String cacheBuster) {
        Id userId = UserInfo.getUserId();
        List<Id> activeTerritories = getActiveGanttTerritories(userId);
        if (activeTerritories.isEmpty()) {
            return new List<FS_AlertCenter__c>();
        }

        return [
            SELECT Id, Name, Status__c, CreatedDate, Alert_Type__c,
                   Service_Appointment__c,
                   Service_Appointment__r.AppointmentNumber,
                   Service_Appointment__r.Priority__c,
                   Service_Appointment__r.EarliestStartTime,
                   Service_Appointment__r.DueDate,
                   Service_Appointment__r.Street,
                   Service_Appointment__r.City,
                   Service_Territory__r.Name,
                   Panic_Service_Resource__c,
                   Panic_Service_Resource__r.Name,
                   Panic_Service_Resource__r.RelatedRecord.Phone,
                   Panic_Service_Resource__r.RelatedRecord.EmployeeNumber,
                   Nature_of_the_Emergency__c,
                   Last_Known_Latitude__c,
                   Last_Known_Longitude__c
            FROM FS_AlertCenter__c
            WHERE (Status__c = 'New' OR (Status__c = 'Acknowledged' AND LastModifiedById = :userId))
            AND Service_Territory__c IN :activeTerritories
            AND Id NOT IN (
                SELECT AlertCenter__c
                FROM FS_Alert_Dismissal__c
                WHERE User__c = :userId
            )
            WITH SYSTEM_MODE
            ORDER BY Alert_Type__c, CreatedDate ASC
        ];
    }

    /**
     * @description Globally acknowledges an alert.
     * @param alertId The ID of the FS_AlertCenter__c record.
     */
    @AuraEnabled
    public static void acknowledgeAlert(Id alertId) {
        update as system new FS_AlertCenter__c(Id = alertId, Status__c = 'Acknowledged');
    }

    /**
     * @description Dismisses an alert locally for the current user.
     * If the alert is Acknowledged, it reverts to New to reappear globally.
     * @param alertId The ID of the FS_AlertCenter__c record.
     */
    @AuraEnabled
    public static void dismissAlert(Id alertId) {
        FS_AlertCenter__c alert = [
            SELECT Id, Status__c
            FROM FS_AlertCenter__c
            WHERE Id = :alertId
            WITH SYSTEM_MODE
            LIMIT 1
        ];

        if (alert.Status__c == 'Acknowledged') {
            alert.Status__c = 'New';
            update as system alert;
        } else {
            insert as system new FS_Alert_Dismissal__c(
                AlertCenter__c = alertId,
                User__c = UserInfo.getUserId()
            );
        }
    }

    /**
     * @description Bulk dismisses currently visible alerts locally for the current user.
     * Reverts any Acknowledged alerts back to New globally.
     * @param alertIds List of FS_AlertCenter__c IDs.
     */
    @AuraEnabled
    public static void dismissAllAlerts(List<Id> alertIds) {
        if (alertIds == null || alertIds.isEmpty()) {
            return;
        }

        List<FS_AlertCenter__c> alertsToProcess = [
            SELECT Id, Status__c
            FROM FS_AlertCenter__c
            WHERE Id IN :alertIds
            WITH SYSTEM_MODE
        ];
        List<FS_Alert_Dismissal__c> dismissalsToInsert = new List<FS_Alert_Dismissal__c>();
        List<FS_AlertCenter__c> alertsToRevert = new List<FS_AlertCenter__c>();
        Id userId = UserInfo.getUserId();

        for (FS_AlertCenter__c alert : alertsToProcess) {
            if (alert.Status__c == 'Acknowledged') {
                alert.Status__c = 'New';
                alertsToRevert.add(alert);
            } else {
                dismissalsToInsert.add(new FS_Alert_Dismissal__c(
                    AlertCenter__c = alert.Id,
                    User__c = userId
                ));
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
            }
            return 'Failed to publish Gantt filter event.';
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
            List<FS_Alert_Dismissal__c> dismissals = [
                SELECT Id
                FROM FS_Alert_Dismissal__c
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