import { LightningElement, track, wire, api } from 'lwc';
import { subscribe, unsubscribe, onError, isEmpEnabled } from 'lightning/empApi';
import { EnclosingUtilityId, updateUtility, updatePanel } from 'lightning/platformUtilityBarApi';
import { NavigationMixin } from 'lightning/navigation';
import alertBuzzer from '@salesforce/resourceUrl/UUAlertBuzzer';
import getActiveAlerts from '@salesforce/apex/JobAlertUtilityController.getActiveAlerts';
import acknowledgeAlert from '@salesforce/apex/JobAlertUtilityController.acknowledgeAlert';
import dismissAlert from '@salesforce/apex/JobAlertUtilityController.dismissAlert';
import dismissAllAlerts from '@salesforce/apex/JobAlertUtilityController.dismissAllAlerts';
import createTemporaryGanttFilter from '@salesforce/apex/JobAlertUtilityController.createTemporaryGanttFilter';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import undoAllDismissals from '@salesforce/apex/JobAlertUtilityController.undoAllDismissals';

export default class JobAlertUtility extends NavigationMixin(LightningElement) {
    @api isCommunityMode = false;

    @track alerts = [];
    @track allAlerts = [];

    // Community Context Management
    @track isCommunityPanelOpen = false;
    @track pollingInterval; // Holds the interval value so we can clear it later

    subscription = {};
    channelName = '/data/Job_Alert__ChangeEvent';
    buzzerUrl = alertBuzzer;

    // subscription = {};
    // channelName = '/event/Job_Alert_Event__e'; // Swapped from CDC to Platform Event
    // buzzerUrl = alertBuzzer;

    @wire(EnclosingUtilityId) utilityId;
    _isUtilityBarInitialized = false;

    // connectedCallback() {
    //     this.loadWorkGroups(); 
    //     this.loadAlerts(false);
    //     // NEW: Register error listener to catch subscription blocks
    //     onError(error => {
    //         console.error('EMP API Streaming Error: ', JSON.stringify(error));
    //     });
    //     this.handleSubscribe();
    // }

    connectedCallback() {
        console.log('🚀 Job Alert Utility Connected!');
        console.log('➡️ Raw isCommunityMode flag is: ', this.isCommunityMode);

        this.loadAlerts(false);

        // 1. Evaluate community mode immediately
        const isCommunity = (this.isCommunityMode === true || this.isCommunityMode === 'true');

        if (isCommunity) {
            // COMMUNITY: Skip empApi entirely. Go straight to Smart Polling.
            console.log('🏢 Community Mode Detected: Initiating Smart Polling...');
            this.startSmartPolling();
            
        } else {
            // INTERNAL: Safe to evaluate and use empApi
            console.log('⚙️ Internal Mode Detected: Initiating empApi Subscription...');
            
            isEmpEnabled().then(enabled => {
                if (!enabled) {
                    console.error('EMP API is NOT ENABLED for this internal user.');
                    return;
                }
                
                onError(error => {
                    console.error('EMP API Streaming Error: ', JSON.stringify(error));
                });
                
                this.handleSubscribe();
            });
        }
    }

    renderedCallback() {
        if (this.utilityId && !this._isUtilityBarInitialized) {
            this._isUtilityBarInitialized = true;
            this.updateUtilityBar(false);
        }
    }

    disconnectedCallback() {
        // Clean up the subscription for internal users
        this.handleUnsubscribe();
        
        // Clean up the poll for portal users so it doesn't run in the background endlessly
        if (this.pollingInterval) {
            clearInterval(this.pollingInterval);
        }
    }

    get isUtilityBarContext() {
        return this.utilityId !== undefined && this.utilityId !== null && this.utilityId !== false;
    }

    get panelContainerClass() {
        if (this.isUtilityBarContext) {
            return 'slds-panel slds-panel_docked slds-panel_docked-left slds-is-open slds-h-100';
        }
        return this.isCommunityPanelOpen ? 'community-panel-container open' : 'community-panel-container closed';
    }

    get alertCount() { return this.alerts ? this.alerts.length : 0; }
    get hasAlerts() { return this.alerts && this.alerts.length > 0; }

    toggleCommunityPanel() {
        this.isCommunityPanelOpen = !this.isCommunityPanelOpen;
    }

    runFilters(hasNewRelevantAlert) {
        this.alerts = [...this.allAlerts];
        this.updateUtilityBar(hasNewRelevantAlert);
    }

    handleRefresh() {
        this.loadAlerts(false);
        this.showToast('Synced', 'Territory filters updated', 'success', 'pester');
    }

    loadAlerts(isNewAlertEvent) {
        // Capture existing alert IDs before querying to detect genuinely new alerts for this specific user
        const oldAlertIds = new Set(this.allAlerts.map(a => a.Id));

        // NEW: Generate a unique timestamp so the browser NEVER caches this request
        const currentTimestamp = new Date().getTime().toString();

        getActiveAlerts({ cacheBuster: currentTimestamp })
            .then(result => {
                this.allAlerts = result.map(record => {
                    const sa = record.Service_Appointment__r || {};
                    //const wt = sa.WorkType || {};
                    const wotNumber = sa.Ellipse_WorkOrderTask_Number__c || 'N/A';

                    let addressParts = [];
                    if (sa.Street) addressParts.push(sa.Street);
                    if (sa.City) addressParts.push(sa.City);

                    return {
                        ...record,
                        saId: record.Service_Appointment__c,
                        saNumber: sa.AppointmentNumber,
                        priority: sa.WorkOrderTask_Priority__c || 'N/A',
                        earlyStart: sa.EarliestStartTime,
                        dueDate: sa.DueDate,
                        workType: sa.Maintenance_Type__c || 'N/A',
                        address: addressParts.length > 0 ? addressParts.join(', ') : 'No Address Provided',
                        territoryName: record.Service_Territory__r ? record.Service_Territory__r.Name : 'Unknown',
                        createdDate: record.CreatedDate,
                        woTaskNumber: wotNumber,
                        isAcknowledged: record.Status__c === 'Acknowledged'
                    };
                });

                // CDC FIX: Only notify if the new alerts contain a record matching the user's Territories
                let hasNewRelevantAlert = false;
                if (isNewAlertEvent) {
                    hasNewRelevantAlert = this.allAlerts.some(alert => !oldAlertIds.has(alert.Id));
                    if (hasNewRelevantAlert) {
                        this.showToast('🚨 New High Priority Job!', 'A new high-priority job has been assigned to your Territory.', 'warning', 'sticky');
                        
                        // Auto-open panel for community users on critical alert
                        if (this.isCommunityMode) {
                            this.isCommunityPanelOpen = true;
                        }
                    }
                }

                this.runFilters(hasNewRelevantAlert);
            })
            .catch(error => console.error('Error loading alerts', error));
    }

    handleCopy(event) {
        const saNumber = event.target.dataset.sa;
        if (navigator.clipboard && window.isSecureContext) {
            navigator.clipboard.writeText(saNumber)
                .then(() => this.showToast('Copied!', `${saNumber} copied to clipboard`, 'success', 'pester'))
                .catch(() => this.fallbackCopy(saNumber)); 
        } else {
            this.fallbackCopy(saNumber);
        }
    }

    fallbackCopy(text) {
        const hiddenInput = document.createElement('input');
        hiddenInput.setAttribute('value', text);
        document.body.appendChild(hiddenInput);
        hiddenInput.select();
        try {
            document.execCommand('copy');
            this.showToast('Copied!', `${text} copied to clipboard`, 'success', 'pester');
        } catch (err) {
            this.showToast('Error', 'Failed to copy to clipboard', 'error', 'dismissible');
        }
        document.body.removeChild(hiddenInput);
    }

    handleNavigate(event) {
        const recordId = event.target.dataset.id;
        this[NavigationMixin.Navigate]({
            type: 'standard__recordPage',
            attributes: {
                recordId: recordId,
                actionName: 'view'
            }
        });
    }

    handleFilterGantt(event) {
        const recordId = event.target.dataset.id;
        const alertRecord = this.allAlerts.find(a => a.saId === recordId);
        const saNumber = alertRecord ? alertRecord.saNumber : 'Selected SA';

        createTemporaryGanttFilter({ saId: recordId, saNumber: saNumber })
            .then(result => {
                if (result === 'Success') {
                    this.showToast('Gantt Filter Applied', `Appointment list updated to show ${saNumber}`, 'success', 'dismissible');
                } else {
                    this.showToast('Warning', result, 'warning', 'dismissible');
                }
            })
            .catch(error => {
                console.error('Error applying Gantt filter', error);
                this.showToast('Error', 'Failed to update Gantt view.', 'error', 'dismissible');
            });
    }

    handleUndoDismissAll() {
        undoAllDismissals()
            .then(() => {
                this.showToast('Restored', 'Previously dismissed alerts have been restored.', 'success', 'dismissible');
                this.loadAlerts(false);
            })
            .catch(error => {
                console.error('Error restoring alerts', error);
                this.showToast('Error', 'Failed to restore alerts.', 'error', 'dismissible');
            });
    }

    updateUtilityBar(hasNewRelevantAlert) {
        // Safe-guard: Only execute Utility Bar API if utilityId is available
        if (!this.utilityId || !this.isUtilityBarContext) {
            // For community, we just play the buzzer if applicable
            if (hasNewRelevantAlert) this.playBuzzer();
            return;
        }

        const count = this.alerts ? this.alerts.length : 0;
        const newLabel = count > 0 ? `High Priority Job Alerts (${count})` : 'High Priority Job Alerts';
        
        // Highlight logic fires if a new relevant alert arrives (based purely on Membership constraints), 
        // irrespective of whether the user's current UI checkbox filter is actively hiding it.
        const shouldHighlight = Boolean(hasNewRelevantAlert);

        updateUtility(this.utilityId, { label: newLabel, highlighted: shouldHighlight }).catch(e => console.error(e));
        updatePanel(this.utilityId, { label: newLabel }).catch(e => console.error(e));

        if (shouldHighlight) {
            this.playBuzzer();
        }
    }

    playBuzzer() {
        try {
            const audioEl = this.template.querySelector('.alert-buzzer');
            if (audioEl) audioEl.play().catch(e => console.warn('Browser blocked audio playback.', e));
        } catch (error) {
            console.error('Audio play error:', error);
        }
    }

    handleAcknowledge(event) {
        const alertId = event.target.dataset.id;
        acknowledgeAlert({ alertId: alertId })
            .then(() => {
                this.showToast('Success', 'Alert Acknowledged Globally', 'success', 'dismissible');
                this.loadAlerts(false);
            })
            .catch(error => console.error('Error acknowledging alert', error));
    }

    handleDismiss(event) {
        const alertId = event.target.dataset.id;
        dismissAlert({ alertId: alertId })
            .then(() => {
                this.allAlerts = this.allAlerts.filter(alert => alert.Id !== alertId);
                this.runFilters(false);
            })
            .catch(error => console.error('Error dismissing alert', error));
    }

    handleDismissAll() {
        if (!this.alerts || this.alerts.length === 0) return;
        
        // Filter out acknowledged alerts so they are ignored by Dismiss All
        const alertsToDismiss = this.alerts.filter(alert => !alert.isAcknowledged);
        
        if (alertsToDismiss.length === 0) {
            this.showToast('Info', 'No new alerts to dismiss.', 'info', 'dismissible');
            return;
        }

        const alertIds = alertsToDismiss.map(alert => alert.Id);
        
        dismissAllAlerts({ alertIds: alertIds })
            .then(() => {
                this.allAlerts = this.allAlerts.filter(alert => !alertIds.includes(alert.Id));
                this.runFilters(false);
            })
            .catch(error => console.error('Error dismissing all', error));
    }

    // handleSubscribe() {
    //     const messageCallback = (response) => {
    //         const changeType = response.data?.payload?.ChangeEventHeader?.changeType;
    //         if (changeType === 'CREATE') {
    //             // Do not immediately trigger Toast/Audio here. Refresh data and verify against user's specific Work Group memberships first.
    //             this.loadAlerts(true);
    //         } else if (changeType === 'UPDATE') {
    //             this.loadAlerts(false);
    //         }
    //     };
    //     subscribe(this.channelName, -1, messageCallback).then(response => {
    //         this.subscription = response;
    //     });
    // }

    handleSubscribe() {
        console.log('⏳ Attempting to subscribe to: ', this.channelName);
        
        const messageCallback = (response) => {
            console.log('🎉 EVENT RECEIVED IN PORTAL: ', JSON.stringify(response));
            
            //const changeType = response.data?.payload?.Change_Type__c;
            const changeType = response.data?.payload?.ChangeEventHeader?.changeType;
            if (changeType === 'CREATE') {
                this.loadAlerts(true);
            } else if (changeType === 'UPDATE') {
                this.loadAlerts(false);
            }
        };

        subscribe(this.channelName, -1, messageCallback)
            .then(response => {
                this.subscription = response;
                console.log('✅ Successfully subscribed to channel: ', response.channel);
            })
            .catch(error => {
                console.error('❌ Subscription failed: ', JSON.stringify(error));
            });
    }

    startSmartPolling() {
        console.log('⏱️ Smart Polling Initialized (10s intervals)');
        
        this.pollingInterval = setInterval(() => {
            console.log('🔄 [HEARTBEAT] Polling Apex for new alerts...');
            this.loadAlerts(true);
        }, 20000); // Poll every 20 seconds
    }

    handleUnsubscribe() {
        unsubscribe(this.subscription, () => console.log('Unsubscribed'));
    }

    showToast(title, message, variant, mode = 'dismissible') {
        this.dispatchEvent(new ShowToastEvent({
            title,
            message,
            variant,
            mode
        }));
    }
}