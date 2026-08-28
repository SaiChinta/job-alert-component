/**
 * @description Test class for FS_AlertCenterUtilityController and FS_ServiceAppointmentTrigger.
 * Validates active alert queries, CMDT settings, global acknowledgement, personal dismissal
 * (including after acknowledge), type-scoped undo, Gantt filter event publication,
 * Service Appointment Field Services record type gating, and automatic alert creation.
 */
@IsTest
private class FS_AlertCenterUtilityControllerTest {

    /**
     * @description Sets up standard test data including Operating Hours, Service Territory,
     * Work Order, Work Order Line Item, Service Appointment, and Custom Setting.
     */
    @TestSetup
    static void setupTestData() {
        Id userId = UserInfo.getUserId();

        Test.startTest();
        FS_Trigger_Bypass_Setting__c bypass = new FS_Trigger_Bypass_Setting__c(
            SetupOwnerId = userId,
            Bypass_Service_Appointment_Trigger__c = false
        );
        insert bypass;

        OperatingHours oh = new OperatingHours(
            Name = 'Standard Business Hours',
            TimeZone = 'Australia/Brisbane'
        );
        insert oh;

        ServiceTerritory parentTerritory = new ServiceTerritory(
            Name = 'Civil UU',
            OperatingHoursId = oh.Id,
            IsActive = true
        );
        insert parentTerritory;

        ServiceTerritory childTerritory = new ServiceTerritory(
            Name = 'Civil UU - METRO NORTH',
            ParentTerritoryId = parentTerritory.Id,
            OperatingHoursId = oh.Id,
            IsActive = true
        );
        insert childTerritory;

        WorkOrder wo = new WorkOrder(
            Status = 'New',
            Priority = 'Low',
            Description = 'Test Work Order'
        );
        insert wo;

        WorkOrderLineItem woli = new WorkOrderLineItem(
            WorkOrderId = wo.Id,
            ServiceTerritoryId = childTerritory.Id,
            Description = 'Test WOLI',
            Duration = 5,
            DurationType = 'Hours'
        );
        insert woli;

        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId = woli.Id,
            ServiceTerritoryId = childTerritory.Id,
            EarliestStartTime = DateTime.now(),
            DueDate = DateTime.now().addDays(7),
            Status = 'None',
            RecordTypeId = getFieldServicesRecordTypeId()
        );
        insert sa;

        FSL__UserSetting__c userSetting = new FSL__UserSetting__c(FSL__User__c = userId);
        insert userSetting;
        insert new FSL__User_Setting_Territory__c(
            FSL__User_Setting__c = userSetting.Id,
            FSL__Service_Territory__c = childTerritory.Id
        );

        insert new FS_AlertCenter__c(
            Service_Appointment__c = sa.Id,
            Service_Territory__c = childTerritory.Id,
            Status__c = 'New',
            Alert_Type__c = 'High Priority Alert'
        );
        Test.stopTest();
    }

    /**
     * @description Returns the packaged Field Services record type Id for Service Appointment.
     * @return The Field_Services record type Id.
     */
    private static Id getFieldServicesRecordTypeId() {
        Schema.RecordTypeInfo info = Schema.SObjectType.ServiceAppointment.getRecordTypeInfosByDeveloperName()
            .get('Field_Services');
        System.assertNotEquals(null, info, 'The Field_Services record type must exist on Service Appointment.');
        return info.getRecordTypeId();
    }

    /**
     * @description Applies in-memory Default_Setting values so tests do not depend on org CMDT toggles.
     * @param priorityEnabled Whether Priority Alerts should be treated as enabled.
     * @param panicEnabled Whether Panic Alerts should be treated as enabled.
     */
    private static void applyAlertCenterSettingsOverride(Boolean priorityEnabled, Boolean panicEnabled) {
        FS_Alert_Center_Setting__mdt setting = new FS_Alert_Center_Setting__mdt(
            Priority_Alerts_Enabled__c = priorityEnabled,
            Panic_Alerts_Enabled__c = panicEnabled,
            Alert_Priorities__c = 'High,Critical,Jeopardy'
        );
        FS_AlertCenterUtilityController.settingsOverride = setting;
        FS_ServiceAppointmentTriggerHandler.settingsOverride = setting;
    }

    /**
     * @description Tests getAlertCenterSettings using a test override, independent of org CMDT toggles.
     */
    @IsTest
    static void testGetAlertCenterSettings() {
        applyAlertCenterSettingsOverride(true, true);

        Test.startTest();
        FS_AlertCenterUtilityController.AlertCenterSettings settings =
            FS_AlertCenterUtilityController.getAlertCenterSettings();
        Test.stopTest();

        System.assertEquals(true, settings.priorityAlertsEnabled, 'Priority alerts should follow the test override.');
        System.assertEquals(true, settings.panicAlertsEnabled, 'Panic alerts should follow the test override.');
    }

    /**
     * @description Tests getAlertCenterSettings when both types are disabled in the test override.
     */
    @IsTest
    static void testGetAlertCenterSettingsDisabled() {
        applyAlertCenterSettingsOverride(false, false);

        Test.startTest();
        FS_AlertCenterUtilityController.AlertCenterSettings settings =
            FS_AlertCenterUtilityController.getAlertCenterSettings();
        Test.stopTest();

        System.assertEquals(false, settings.priorityAlertsEnabled, 'Priority alerts should be disabled when the override is false.');
        System.assertEquals(false, settings.panicAlertsEnabled, 'Panic alerts should be disabled when the override is false.');
    }

    /**
     * @description Tests the getActiveAlerts method to ensure active alerts are retrieved correctly.
     */
    @IsTest
    static void testGetActiveAlertsPositive() {
        Test.startTest();
        List<FS_AlertCenter__c> alerts = FS_AlertCenterUtilityController.getActiveAlerts('test-cache-buster');
        Test.stopTest();

        System.assertEquals(1, alerts.size(), 'Should return the active alert for the user\'s configured territory.');
        System.assertEquals('New', alerts[0].Status__c, 'Status should be New.');
        System.assertEquals('High Priority Alert', alerts[0].Alert_Type__c, 'Setup alert should be a high priority alert.');
    }

    /**
     * @description Tests getActiveAlerts when the user has no active territories.
     */
    @IsTest
    static void testGetActiveAlertsNoTerritories() {
        Test.startTest();
        delete [SELECT Id FROM FSL__User_Setting_Territory__c];

        List<FS_AlertCenter__c> alerts = FS_AlertCenterUtilityController.getActiveAlerts('test-cache-buster');
        Test.stopTest();

        System.assertEquals(0, alerts.size(), 'Should return empty list if user has no active Gantt territories.');
    }

    /**
     * @description Tests that panic alerts in the same Gantt territory are returned with location fields.
     */
    @IsTest
    static void testGetActiveAlertsIncludesPanic() {
        ServiceTerritory childTerritory = [
            SELECT Id
            FROM ServiceTerritory
            WHERE Name = 'Civil UU - METRO NORTH'
            LIMIT 1
        ];

        Profile standardProfile = [SELECT Id FROM Profile WHERE Id = :UserInfo.getProfileId()];
        User panicUser = new User(
            Alias = 'pncusr',
            Email = 'pncusr@example.com',
            EmailEncodingKey = 'UTF-8',
            LastName = 'PanicUser',
            LanguageLocaleKey = 'en_US',
            LocaleSidKey = 'en_US',
            Phone = '0210000000',
            EmployeeNumber = 'EMP001',
            ProfileId = standardProfile.Id,
            TimeZoneSidKey = 'Australia/Brisbane',
            UserName = 'pncusr' + String.valueOf(Crypto.getRandomInteger()) + '@example.com'
        );
        insert panicUser;

        ServiceResource sr;
        System.runAs(new User(Id = UserInfo.getUserId())) {
            sr = new ServiceResource(
                Name = 'Panic Resource',
                RelatedRecordId = panicUser.Id,
                IsActive = true,
                ResourceType = 'T'
            );
            insert sr;

            insert new FS_AlertCenter__c(
                Alert_Type__c = 'Panic Alert',
                Panic_Service_Resource__c = sr.Id,
                Service_Territory__c = childTerritory.Id,
                Status__c = 'New',
                Nature_of_the_Emergency__c = 'Medical crisis',
                Last_Known_Latitude__c = -36.848461,
                Last_Known_Longitude__c = 174.763336
            );
        }

        Test.startTest();
        List<FS_AlertCenter__c> alerts = FS_AlertCenterUtilityController.getActiveAlerts('test-cache-buster');
        Test.stopTest();

        Boolean foundPanic = false;
        for (FS_AlertCenter__c alert : alerts) {
            if (alert.Alert_Type__c == 'Panic Alert') {
                foundPanic = true;
                System.assertEquals(sr.Id, alert.Panic_Service_Resource__c, 'Panic alert should reference the service resource.');
                System.assertEquals(-36.848461, alert.Last_Known_Latitude__c, 'Latitude should be returned for panic alerts.');
                System.assertEquals(174.763336, alert.Last_Known_Longitude__c, 'Longitude should be returned for panic alerts.');
                System.assertEquals('Medical crisis', alert.Nature_of_the_Emergency__c, 'Nature of the emergency should be returned.');
                System.assertEquals('0210000000', alert.Panic_Service_Resource__r.RelatedRecord.Phone, 'Resource phone should be returned.');
                System.assertEquals('EMP001', alert.Panic_Service_Resource__r.RelatedRecord.EmployeeNumber, 'Resource employee number should be returned.');
            }
        }
        System.assertEquals(true, foundPanic, 'Active alerts should include the panic record in the Gantt territory.');
    }

    /**
     * @description Tests global acknowledgement of an Alert Center record.
     */
    @IsTest
    static void testAcknowledgeAlert() {
        FS_AlertCenter__c alert = [SELECT Id FROM FS_AlertCenter__c LIMIT 1];

        Test.startTest();
        FS_AlertCenterUtilityController.acknowledgeAlert(alert.Id);
        Test.stopTest();

        FS_AlertCenter__c updatedAlert = [SELECT Status__c FROM FS_AlertCenter__c WHERE Id = :alert.Id];
        System.assertEquals('Acknowledged', updatedAlert.Status__c, 'Alert status should be updated to Acknowledged.');
    }

    /**
     * @description Tests personal dismissal of an Alert Center record.
     */
    @IsTest
    static void testDismissAlertsLocally() {
        FS_AlertCenter__c alert = [SELECT Id FROM FS_AlertCenter__c LIMIT 1];

        Test.startTest();
        FS_AlertCenterUtilityController.dismissAlert(alert.Id);
        Test.stopTest();

        List<FS_Alert_Dismissal__c> dismissals = [
            SELECT Id, User__c
            FROM FS_Alert_Dismissal__c
            WHERE AlertCenter__c = :alert.Id
        ];
        System.assertEquals(1, dismissals.size(), 'A personal dismissal record should be created.');
        System.assertEquals(UserInfo.getUserId(), dismissals[0].User__c, 'Dismissal should be linked to the current user.');

        List<FS_AlertCenter__c> activeAlerts = FS_AlertCenterUtilityController.getActiveAlerts('test-cache-buster');
        System.assertEquals(0, activeAlerts.size(), 'Dismissed alerts should be filtered out from the active query.');
    }

    /**
     * @description Tests that dismissing an acknowledged alert inserts a personal dismissal
     * and reverts status to New so it does not resurface for the dismissing user.
     */
    @IsTest
    static void testDismissAcknowledgedAlertCreatesDismissal() {
        FS_AlertCenter__c alert = [SELECT Id, Status__c FROM FS_AlertCenter__c LIMIT 1];
        alert.Status__c = 'Acknowledged';
        update alert;

        Test.startTest();
        FS_AlertCenterUtilityController.dismissAlert(alert.Id);
        Test.stopTest();

        FS_AlertCenter__c updatedAlert = [SELECT Status__c FROM FS_AlertCenter__c WHERE Id = :alert.Id];
        System.assertEquals('New', updatedAlert.Status__c, 'The acknowledged alert should revert back to New.');

        List<FS_Alert_Dismissal__c> dismissals = [
            SELECT Id, User__c
            FROM FS_Alert_Dismissal__c
            WHERE AlertCenter__c = :alert.Id
        ];
        System.assertEquals(1, dismissals.size(), 'A personal dismissal record should be created when dismissing an acknowledged alert.');
        System.assertEquals(UserInfo.getUserId(), dismissals[0].User__c, 'Dismissal should be linked to the current user.');

        List<FS_AlertCenter__c> activeAlerts = FS_AlertCenterUtilityController.getActiveAlerts('test-cache-buster');
        System.assertEquals(0, activeAlerts.size(), 'The dismissed alert should not resurface for the dismissing user.');
    }

    /**
     * @description Tests bulk dismissal of Alert Center records.
     */
    @IsTest
    static void testDismissAllAlerts() {
        FS_AlertCenter__c alert = [SELECT Id FROM FS_AlertCenter__c LIMIT 1];
        List<Id> alertIds = new List<Id>{ alert.Id };

        Test.startTest();
        FS_AlertCenterUtilityController.dismissAllAlerts(alertIds);
        Test.stopTest();

        List<FS_Alert_Dismissal__c> dismissals = [
            SELECT Id
            FROM FS_Alert_Dismissal__c
            WHERE AlertCenter__c = :alert.Id
        ];
        System.assertEquals(1, dismissals.size(), 'A personal dismissal record should be created during bulk dismiss.');
    }

    /**
     * @description Tests bulk dismissal with mixed statuses (e.g. Acknowledged and New).
     */
    @IsTest
    static void testDismissAllAlertsMixedStatuses() {
        FS_AlertCenter__c alert = [SELECT Id FROM FS_AlertCenter__c LIMIT 1];
        alert.Status__c = 'Acknowledged';
        update alert;

        List<Id> alertIds = new List<Id>{ alert.Id };

        Test.startTest();
        FS_AlertCenterUtilityController.dismissAllAlerts(alertIds);
        Test.stopTest();

        List<FS_Alert_Dismissal__c> dismissals = [
            SELECT Id
            FROM FS_Alert_Dismissal__c
            WHERE AlertCenter__c = :alert.Id
        ];
        System.assertEquals(1, dismissals.size(), 'A personal dismissal record should be created for Acknowledged alerts during bulk dismiss.');

        FS_AlertCenter__c updatedAlert = [SELECT Status__c FROM FS_AlertCenter__c WHERE Id = :alert.Id];
        System.assertEquals('New', updatedAlert.Status__c, 'The Acknowledged alert should revert to New during bulk dismiss.');

        List<FS_AlertCenter__c> activeAlerts = FS_AlertCenterUtilityController.getActiveAlerts('test-cache-buster');
        System.assertEquals(0, activeAlerts.size(), 'The bulk-dismissed alert should not resurface for the dismissing user.');
    }

    /**
     * @description Tests bulk dismissal when no alert IDs are supplied.
     */
    @IsTest
    static void testDismissAllAlertsEmpty() {
        Test.startTest();
        FS_AlertCenterUtilityController.dismissAllAlerts(new List<Id>());
        Test.stopTest();

        List<FS_Alert_Dismissal__c> dismissals = [SELECT Id FROM FS_Alert_Dismissal__c];
        System.assertEquals(0, dismissals.size(), 'No dismissals should be created for an empty request.');
    }

    /**
     * @description Tests the createTemporaryGanttFilter method.
     */
    @IsTest
    static void testCreateTemporaryGanttFilter() {
        ServiceAppointment sa = [SELECT Id FROM ServiceAppointment LIMIT 1];

        Test.startTest();
        String result = FS_AlertCenterUtilityController.createTemporaryGanttFilter(sa.Id, 'SA-0001');
        Test.stopTest();

        System.assertEquals('Success', result, 'The Gantt Platform Event should publish successfully.');
    }

    /**
     * @description Tests undoing today's High Priority Alert dismissals for the current user.
     */
    @IsTest
    static void testUndoAllDismissals() {
        FS_AlertCenter__c alert = [SELECT Id FROM FS_AlertCenter__c LIMIT 1];
        insert new FS_Alert_Dismissal__c(AlertCenter__c = alert.Id, User__c = UserInfo.getUserId());

        System.assertEquals(0, FS_AlertCenterUtilityController.getActiveAlerts('test-cache-buster').size(), 'Alert should be hidden initially.');

        Test.startTest();
        FS_AlertCenterUtilityController.undoAllDismissals('High Priority Alert');
        Test.stopTest();

        System.assertEquals(1, FS_AlertCenterUtilityController.getActiveAlerts('test-cache-buster').size(), 'Alert should reappear after undoing dismissals.');
        List<FS_Alert_Dismissal__c> dismissals = [SELECT Id FROM FS_Alert_Dismissal__c];
        System.assertEquals(0, dismissals.size(), 'The dismissal records should be deleted.');
    }

    /**
     * @description Tests that undoing High Priority dismissals does not restore Panic dismissals.
     */
    @IsTest
    static void testUndoDismissalsDoesNotRestoreOtherType() {
        ServiceTerritory childTerritory = [
            SELECT Id
            FROM ServiceTerritory
            WHERE Name = 'Civil UU - METRO NORTH'
            LIMIT 1
        ];
        FS_AlertCenter__c priorityAlert = [
            SELECT Id
            FROM FS_AlertCenter__c
            WHERE Alert_Type__c = 'High Priority Alert'
            LIMIT 1
        ];
        FS_AlertCenter__c panicAlert = new FS_AlertCenter__c(
            Alert_Type__c = 'Panic Alert',
            Service_Territory__c = childTerritory.Id,
            Status__c = 'New'
        );
        insert panicAlert;

        insert new List<FS_Alert_Dismissal__c>{
            new FS_Alert_Dismissal__c(AlertCenter__c = priorityAlert.Id, User__c = UserInfo.getUserId()),
            new FS_Alert_Dismissal__c(AlertCenter__c = panicAlert.Id, User__c = UserInfo.getUserId())
        };

        Test.startTest();
        FS_AlertCenterUtilityController.undoAllDismissals('High Priority Alert');
        Test.stopTest();

        List<FS_Alert_Dismissal__c> remaining = [
            SELECT AlertCenter__c
            FROM FS_Alert_Dismissal__c
        ];
        System.assertEquals(1, remaining.size(), 'Only the Panic Alert dismissal should remain.');
        System.assertEquals(panicAlert.Id, remaining[0].AlertCenter__c, 'The remaining dismissal should be the Panic Alert.');
    }

    /**
     * @description Tests that undoing Panic dismissals does not restore High Priority dismissals.
     */
    @IsTest
    static void testUndoDismissalsPanicDoesNotRestorePriority() {
        ServiceTerritory childTerritory = [
            SELECT Id
            FROM ServiceTerritory
            WHERE Name = 'Civil UU - METRO NORTH'
            LIMIT 1
        ];
        FS_AlertCenter__c priorityAlert = [
            SELECT Id
            FROM FS_AlertCenter__c
            WHERE Alert_Type__c = 'High Priority Alert'
            LIMIT 1
        ];
        FS_AlertCenter__c panicAlert = new FS_AlertCenter__c(
            Alert_Type__c = 'Panic Alert',
            Service_Territory__c = childTerritory.Id,
            Status__c = 'New'
        );
        insert panicAlert;

        insert new List<FS_Alert_Dismissal__c>{
            new FS_Alert_Dismissal__c(AlertCenter__c = priorityAlert.Id, User__c = UserInfo.getUserId()),
            new FS_Alert_Dismissal__c(AlertCenter__c = panicAlert.Id, User__c = UserInfo.getUserId())
        };

        Test.startTest();
        FS_AlertCenterUtilityController.undoAllDismissals('Panic Alert');
        Test.stopTest();

        List<FS_Alert_Dismissal__c> remaining = [
            SELECT AlertCenter__c
            FROM FS_Alert_Dismissal__c
        ];
        System.assertEquals(1, remaining.size(), 'Only the High Priority Alert dismissal should remain.');
        System.assertEquals(priorityAlert.Id, remaining[0].AlertCenter__c, 'The remaining dismissal should be the High Priority Alert.');
    }

    /**
     * @description Tests that a blank or unknown alert type does not delete dismissals.
     */
    @IsTest
    static void testUndoDismissalsIgnoresBlankAndUnknownType() {
        FS_AlertCenter__c alert = [SELECT Id FROM FS_AlertCenter__c LIMIT 1];
        insert new FS_Alert_Dismissal__c(AlertCenter__c = alert.Id, User__c = UserInfo.getUserId());

        Test.startTest();
        FS_AlertCenterUtilityController.undoAllDismissals(null);
        FS_AlertCenterUtilityController.undoAllDismissals('');
        FS_AlertCenterUtilityController.undoAllDismissals('Unknown Type');
        Test.stopTest();

        List<FS_Alert_Dismissal__c> dismissals = [SELECT Id FROM FS_Alert_Dismissal__c];
        System.assertEquals(1, dismissals.size(), 'Blank or unknown alert types should not delete dismissals.');
    }

    /**
     * @description Tests the ServiceAppointmentTrigger field population and auto alert generation.
     */
    @IsTest
    static void testServiceAppointmentTrigger() {
        applyAlertCenterSettingsOverride(true, true);
        ServiceTerritory territory = [SELECT Id FROM ServiceTerritory WHERE IsActive = true LIMIT 1];

        WorkOrder woHigh = new WorkOrder(
            Status = 'New',
            Priority = 'High',
            Description = 'High Priority WO'
        );
        insert woHigh;

        WorkOrderLineItem woliHigh = new WorkOrderLineItem(
            WorkOrderId = woHigh.Id,
            Description = 'High Priority WOLI'
        );
        insert woliHigh;

        Test.startTest();
        ServiceAppointment saHigh = new ServiceAppointment(
            ParentRecordId = woliHigh.Id,
            ServiceTerritoryId = territory.Id,
            EarliestStartTime = DateTime.now(),
            DueDate = DateTime.now().addDays(7),
            Status = 'None',
            RecordTypeId = getFieldServicesRecordTypeId()
        );
        insert saHigh;
        Test.stopTest();

        ServiceAppointment saResult = [
            SELECT FS_Work_Order_Line_Item__c, FS_Work_Order__c, Priority__c
            FROM ServiceAppointment
            WHERE Id = :saHigh.Id
        ];
        System.assertEquals(woliHigh.Id, saResult.FS_Work_Order_Line_Item__c, 'WOLI lookup should be populated.');
        System.assertEquals(woHigh.Id, saResult.FS_Work_Order__c, 'Parent Work Order lookup should be populated.');

        List<FS_AlertCenter__c> alerts = [
            SELECT Id, Status__c, Service_Appointment__c, Alert_Type__c
            FROM FS_AlertCenter__c
            WHERE Service_Appointment__c = :saHigh.Id
        ];
        System.assertEquals(1, alerts.size(), 'An Alert Center record should have been automatically generated for the High priority Service Appointment.');
        System.assertEquals('High Priority Alert', alerts[0].Alert_Type__c, 'Trigger-created alerts should be High Priority Alert type.');
    }

    /**
     * @description Tests that High Priority Alerts are not created when Priority Alerts are disabled.
     */
    @IsTest
    static void testServiceAppointmentTriggerSkipsWhenPriorityDisabled() {
        applyAlertCenterSettingsOverride(false, true);
        ServiceTerritory territory = [SELECT Id FROM ServiceTerritory WHERE IsActive = true LIMIT 1];

        WorkOrder woHigh = new WorkOrder(
            Status = 'New',
            Priority = 'High',
            Description = 'High Priority WO Disabled Flag'
        );
        insert woHigh;

        WorkOrderLineItem woliHigh = new WorkOrderLineItem(
            WorkOrderId = woHigh.Id,
            Description = 'High Priority WOLI Disabled Flag'
        );
        insert woliHigh;

        Test.startTest();
        ServiceAppointment saHigh = new ServiceAppointment(
            ParentRecordId = woliHigh.Id,
            ServiceTerritoryId = territory.Id,
            EarliestStartTime = DateTime.now(),
            DueDate = DateTime.now().addDays(7),
            Status = 'None',
            RecordTypeId = getFieldServicesRecordTypeId()
        );
        insert saHigh;
        Test.stopTest();

        List<FS_AlertCenter__c> alerts = [
            SELECT Id
            FROM FS_AlertCenter__c
            WHERE Service_Appointment__c = :saHigh.Id
        ];
        System.assertEquals(0, alerts.size(), 'No High Priority Alert should be created when Priority Alerts are disabled.');
    }

    /**
     * @description Tests that before-insert lookup population is skipped when the record type is not Field Services.
     */
    @IsTest
    static void testTriggerSkipsNonFieldServicesBeforeInsert() {
        WorkOrderLineItem woli = [SELECT Id FROM WorkOrderLineItem LIMIT 1];
        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId = woli.Id,
            RecordTypeId = UserInfo.getUserId()
        );

        Test.startTest();
        FS_ServiceAppointmentTriggerHandler.handleTrigger(
            new List<ServiceAppointment>{ sa },
            null,
            System.TriggerOperation.BEFORE_INSERT
        );
        Test.stopTest();

        System.assertEquals(null, sa.FS_Work_Order_Line_Item__c, 'WOLI lookup should not be populated for a non-Field Services record type.');
        System.assertEquals(null, sa.FS_Work_Order__c, 'Work Order lookup should not be populated for a non-Field Services record type.');
    }

    /**
     * @description Tests that after-insert alert creation is skipped when the record type is not Field Services.
     */
    @IsTest
    static void testTriggerSkipsNonFieldServicesAfterInsert() {
        ServiceAppointment sa = [
            SELECT Id, RecordTypeId, FS_Work_Order__c, FS_Work_Order_Line_Item__c
            FROM ServiceAppointment
            LIMIT 1
        ];
        sa.RecordTypeId = UserInfo.getUserId();
        Integer alertCountBefore = [
            SELECT COUNT()
            FROM FS_AlertCenter__c
            WHERE Alert_Type__c = 'High Priority Alert'
        ];

        Test.startTest();
        FS_ServiceAppointmentTriggerHandler.handleTrigger(
            new List<ServiceAppointment>{ sa },
            null,
            System.TriggerOperation.AFTER_INSERT
        );
        Test.stopTest();

        Integer alertCountAfter = [
            SELECT COUNT()
            FROM FS_AlertCenter__c
            WHERE Alert_Type__c = 'High Priority Alert'
        ];
        System.assertEquals(alertCountBefore, alertCountAfter, 'A non-Field Services record type should not create a High Priority Alert.');
    }
}