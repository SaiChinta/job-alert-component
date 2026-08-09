/**
 * @description Test class for JobAlertUtilityController.
 * Validates active alert queries, global acknowledgement, personal dismissal,
 * revert-to-new behavior, undo functionality, and Gantt filter event publication.
 */
@IsTest
private class JobAlertUtilityControllerTest {
    
    /**
     * @description Sets up standard test data including Operating Hours, Service Territory,
     * Work Order, Work Order Line Item, Service Appointment, and Job Alert.
     */
    @TestSetup
    static void setupTestData() {
        Id userId = UserInfo.getUserId();
        
        Test.startTest();
        // 1. Set up Operating Hours and Service Territory
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

        // 2. Set up Work Order with mandatory fields
        WorkOrder wo = new WorkOrder(
            Status = 'New',
            Priority = 'Low', 
            Description = 'Test Work Order'
        );
        insert wo;

        // 3. Set up Work Order Line Item
        WorkOrderLineItem woli = new WorkOrderLineItem(
            WorkOrderId = wo.Id,
            ServiceTerritoryId = childTerritory.Id,
            Description = 'Test WOLI',
            Duration = 5,
            DurationType = 'Hours'
        );
        insert woli;

        // 4. Set up Service Appointment
        ServiceAppointment sa = new ServiceAppointment(
            ParentRecordId = woli.Id,
            ServiceTerritoryId = childTerritory.Id,
            EarliestStartTime = DateTime.now(),
            DueDate = DateTime.now().addDays(7),
            Status = 'None',
            Work_Order_Task__c = woli.Id
        );
        insert sa;

        // 5. Set up FSL User Settings linked to the child territory
        FSL__UserSetting__c userSetting = new FSL__UserSetting__c(FSL__User__c = userId);
        insert userSetting;
        insert new FSL__User_Setting_Territory__c(
            FSL__User_Setting__c = userSetting.Id, 
            FSL__Service_Territory__c = childTerritory.Id
        );

        // 6. Ensure Alert Exists
        insert new Job_Alert__c(
            Service_Appointment__c = sa.Id, 
            Service_Territory__c = childTerritory.Id, 
            Status__c = 'New'
        );
        Test.stopTest();
    }

    /**
     * @description Tests the getActiveAlerts method to ensure active alerts are retrieved correctly.
     */
    @IsTest
    static void testGetActiveAlertsPositive() {
        Test.startTest();
        List<Job_Alert__c> alerts = JobAlertUtilityController.getActiveAlerts('test-cache-buster');
        Test.stopTest();
        
        System.assertEquals(1, alerts.size(), 'Should return the active alert for the user\'s configured territory.');
        System.assertEquals('New', alerts[0].Status__c, 'Status should be New.');
    }

    /**
     * @description Tests getActiveAlerts when the user has no active territories.
     */
    @IsTest
    static void testGetActiveAlertsNoTerritories() {
        Test.startTest();
        // Remove territory settings for the user
        delete [SELECT Id FROM FSL__User_Setting_Territory__c];
        
        List<Job_Alert__c> alerts = JobAlertUtilityController.getActiveAlerts('test-cache-buster');
        Test.stopTest();
        
        System.assertEquals(0, alerts.size(), 'Should return empty list if user has no active Gantt territories.');
    }

    /**
     * @description Tests global acknowledgement of a Job Alert.
     */
    @IsTest
    static void testAcknowledgeAlert() {
        Job_Alert__c alert = [SELECT Id FROM Job_Alert__c LIMIT 1];
        
        Test.startTest();
        JobAlertUtilityController.acknowledgeAlert(alert.Id);
        Test.stopTest();
        
        Job_Alert__c updatedAlert = [SELECT Status__c FROM Job_Alert__c WHERE Id = :alert.Id];
        System.assertEquals('Acknowledged', updatedAlert.Status__c, 'Alert status should be updated to Acknowledged.');
    }

    /**
     * @description Tests personal dismissal of a Job Alert.
     */
    @IsTest
    static void testDismissAlertsLocally() {
        Job_Alert__c alert = [SELECT Id FROM Job_Alert__c LIMIT 1];
        
        Test.startTest();
        // Dismiss single alert
        JobAlertUtilityController.dismissAlert(alert.Id);
        Test.stopTest();
        
        List<Alert_Dismissal__c> dismissals = [SELECT Id, User__c FROM Alert_Dismissal__c WHERE Job_Alert__c = :alert.Id];
        System.assertEquals(1, dismissals.size(), 'A personal dismissal record should be created.');
        System.assertEquals(UserInfo.getUserId(), dismissals[0].User__c, 'Dismissal should be linked to the current user.');
        
        // Ensure it is now hidden from the user's active alerts
        List<Job_Alert__c> activeAlerts = JobAlertUtilityController.getActiveAlerts('test-cache-buster');
        System.assertEquals(0, activeAlerts.size(), 'Dismissed alerts should be filtered out from the active query.');
    }

    /**
     * @description Tests that dismissing an already acknowledged alert reverts its status to New.
     */
    @IsTest
    static void testDismissAcknowledgedAlertRevertsToNew() {
        Job_Alert__c alert = [SELECT Id, Status__c FROM Job_Alert__c LIMIT 1];
        
        // Setup: Acknowledge the alert first
        alert.Status__c = 'Acknowledged';
        update alert;
        
        Test.startTest();
        // Act: Attempt to dismiss the already acknowledged alert
        JobAlertUtilityController.dismissAlert(alert.Id);
        Test.stopTest();
        
        List<Alert_Dismissal__c> dismissals = [SELECT Id FROM Alert_Dismissal__c WHERE Job_Alert__c = :alert.Id];
        System.assertEquals(0, dismissals.size(), 'A personal dismissal record should NOT be created for an acknowledged alert.');
        
        Job_Alert__c updatedAlert = [SELECT Status__c FROM Job_Alert__c WHERE Id = :alert.Id];
        System.assertEquals('New', updatedAlert.Status__c, 'The acknowledged alert should revert back to New.');
    }

    /**
     * @description Tests bulk dismissal of Job Alerts.
     */
    @IsTest
    static void testDismissAllAlerts() {
        Job_Alert__c alert = [SELECT Id FROM Job_Alert__c LIMIT 1];
        List<Id> alertIds = new List<Id>{ alert.Id };

        Test.startTest();
        JobAlertUtilityController.dismissAllAlerts(alertIds);
        Test.stopTest();

        List<Alert_Dismissal__c> dismissals = [SELECT Id FROM Alert_Dismissal__c WHERE Job_Alert__c = :alert.Id];
        System.assertEquals(1, dismissals.size(), 'A personal dismissal record should be created during bulk dismiss.');
    }

    /**
     * @description Tests bulk dismissal with mixed statuses (e.g. Acknowledged and New).
     */
    @IsTest
    static void testDismissAllAlertsMixedStatuses() {
        Job_Alert__c alert = [SELECT Id FROM Job_Alert__c LIMIT 1];
        // Ensure status is Acknowledged for testing mixed behavior
        alert.Status__c = 'Acknowledged';
        update alert;

        List<Id> alertIds = new List<Id>{ alert.Id };

        Test.startTest();
        JobAlertUtilityController.dismissAllAlerts(alertIds);
        Test.stopTest();

        List<Alert_Dismissal__c> dismissals = [SELECT Id FROM Alert_Dismissal__c WHERE Job_Alert__c = :alert.Id];
        System.assertEquals(0, dismissals.size(), 'Dismissal should be skipped for Acknowledged alerts during bulk dismiss.');
        
        Job_Alert__c updatedAlert = [SELECT Status__c FROM Job_Alert__c WHERE Id = :alert.Id];
        System.assertEquals('New', updatedAlert.Status__c, 'The Acknowledged alert should revert to New during bulk dismiss.');
    }

    /**
     * @description Tests the createTemporaryGanttFilter method.
     */
    @IsTest
    static void testCreateTemporaryGanttFilter() {
        ServiceAppointment sa = [SELECT Id FROM ServiceAppointment LIMIT 1];
        
        Test.startTest();
        String result = JobAlertUtilityController.createTemporaryGanttFilter(sa.Id, 'SA-0001');
        Test.stopTest();
        
        System.assertEquals('Success', result, 'The Gantt Platform Event should publish successfully.');
    }

    /**
     * @description Tests undoing all dismissals for the current user.
     */
    @IsTest
    static void testUndoAllDismissals() {
        Job_Alert__c alert = [SELECT Id FROM Job_Alert__c LIMIT 1];
        // 1. Dismiss the alert
        insert new Alert_Dismissal__c(Job_Alert__c = alert.Id, User__c = UserInfo.getUserId());
        
        System.assertEquals(0, JobAlertUtilityController.getActiveAlerts('test-cache-buster').size(), 'Alert should be hidden initially.');

        Test.startTest();
        // 2. Undo dismissal
        JobAlertUtilityController.undoAllDismissals();
        Test.stopTest();

        // 3. Verify it's back
        System.assertEquals(1, JobAlertUtilityController.getActiveAlerts('test-cache-buster').size(), 'Alert should reappear after undoing dismissals.');
        List<Alert_Dismissal__c> dismissals = [SELECT Id FROM Alert_Dismissal__c];
        System.assertEquals(0, dismissals.size(), 'The dismissal records should be deleted.');
    }
}