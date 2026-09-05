import { LightningElement, track, wire, api } from 'lwc';
import { subscribe, unsubscribe, onError, isEmpEnabled } from 'lightning/empApi';
import { EnclosingUtilityId, updateUtility, updatePanel } from 'lightning/platformUtilityBarApi';
import { NavigationMixin } from 'lightning/navigation';
import alertBuzzer from '@salesforce/resourceUrl/FS_AlertBuzzer';
import getActiveAlerts from '@salesforce/apex/FS_AlertCenterUtilityController.getActiveAlerts';
import getAlertCenterSettings from '@salesforce/apex/FS_AlertCenterUtilityController.getAlertCenterSettings';
import acknowledgeAlert from '@salesforce/apex/FS_AlertCenterUtilityController.acknowledgeAlert';
import dismissAlert from '@salesforce/apex/FS_AlertCenterUtilityController.dismissAlert';
import dismissAllAlerts from '@salesforce/apex/FS_AlertCenterUtilityController.dismissAllAlerts';
import createTemporaryGanttFilter from '@salesforce/apex/FS_AlertCenterUtilityController.createTemporaryGanttFilter';
import undoAllDismissals from '@salesforce/apex/FS_AlertCenterUtilityController.undoAllDismissals';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

const ALERT_TYPE_JOB = 'High Priority Alert';
const ALERT_TYPE_PANIC = 'Panic Alert';
const ALERT_TYPE_CANCELLATION = 'Cancellation Alert';
const ALERT_TYPE_JEOPARDY = 'In Jeopardy Alert';

export default class FsAlertCenterUtility extends NavigationMixin(LightningElement) {
    @api isCommunityMode = false;

    @track allAlerts = [];
    @track isCommunityPanelOpen = false;
    @track activeTab = 'jobs';
    @track priorityAlertsEnabled = true;
    @track panicAlertsEnabled = true;
    @track cancellationAlertsEnabled = false;
    @track jeopardyAlertsEnabled = false;
    @track showPriorityTodayOnly = true;
    @track showPanicTodayOnly = true;
    @track showCancellationTodayOnly = true;
    @track showJeopardyTodayOnly = true;

    pollingInterval;
    subscription = {};
    channelName = '/data/FS_AlertCenter__ChangeEvent';
    buzzerUrl = alertBuzzer;

    @wire(EnclosingUtilityId) utilityId;
    _isUtilityBarInitialized = false;

    @wire(getAlertCenterSettings)
    wiredSettings({ data, error }) {
        if (data) {
            this.priorityAlertsEnabled = data.priorityAlertsEnabled === true;
            this.panicAlertsEnabled = data.panicAlertsEnabled === true;
            this.cancellationAlertsEnabled = data.cancellationAlertsEnabled === true;
            this.jeopardyAlertsEnabled = data.jeopardyAlertsEnabled === true;
            this.activeTab = this.firstEnabledTab();
            this.updateUtilityBar(false);
        } else if (error) {
            this.priorityAlertsEnabled = false;
            this.panicAlertsEnabled = false;
            this.cancellationAlertsEnabled = false;
            this.jeopardyAlertsEnabled = false;
        }
    }

    connectedCallback() {
        this.loadAlerts(false);

        const isCommunity = this.isCommunityMode === true || this.isCommunityMode === 'true';
        if (isCommunity) {
            this.startSmartPolling();
        } else {
            isEmpEnabled().then((enabled) => {
                if (!enabled) {
                    return;
                }
                onError(() => {
                    return;
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
        this.handleUnsubscribe();
        if (this.pollingInterval) {
            clearInterval(this.pollingInterval);
        }
    }

    get isUtilityBarContext() {
        return this.utilityId !== undefined && this.utilityId !== null && this.utilityId !== false;
    }

    get panelContainerClass() {
        if (this.isUtilityBarContext) {
            return 'slds-panel slds-panel_docked slds-panel_docked-left slds-is-open';
        }
        return this.isCommunityPanelOpen ? 'community-panel-container open' : 'community-panel-container closed';
    }

    get showAnyTabs() {
        return this.priorityAlertsEnabled
            || this.panicAlertsEnabled
            || this.cancellationAlertsEnabled
            || this.jeopardyAlertsEnabled;
    }

    get jobAlerts() {
        return this.alertsOfType(ALERT_TYPE_JOB, this.showPriorityTodayOnly);
    }

    get panicAlerts() {
        return this.alertsOfType(ALERT_TYPE_PANIC, this.showPanicTodayOnly);
    }

    get cancellationAlerts() {
        return this.alertsOfType(ALERT_TYPE_CANCELLATION, this.showCancellationTodayOnly);
    }

    get jeopardyAlerts() {
        return this.alertsOfType(ALERT_TYPE_JEOPARDY, this.showJeopardyTodayOnly);
    }

    get hasJobAlerts() {
        return this.jobAlerts.length > 0;
    }

    get hasPanicAlerts() {
        return this.panicAlerts.length > 0;
    }

    get hasCancellationAlerts() {
        return this.cancellationAlerts.length > 0;
    }

    get hasJeopardyAlerts() {
        return this.jeopardyAlerts.length > 0;
    }

    get combinedCount() {
        let count = 0;
        if (this.priorityAlertsEnabled) {
            count += this.jobAlerts.length;
        }
        if (this.panicAlertsEnabled) {
            count += this.panicAlerts.length;
        }
        if (this.cancellationAlertsEnabled) {
            count += this.cancellationAlerts.length;
        }
        if (this.jeopardyAlertsEnabled) {
            count += this.jeopardyAlerts.length;
        }
        return count;
    }

    get hasCombinedAlerts() {
        return this.combinedCount > 0;
    }

    get priorityTabLabel() {
        return 'Priority Alerts (' + this.jobAlerts.length + ')';
    }

    get panicTabLabel() {
        return 'Panic Alerts (' + this.panicAlerts.length + ')';
    }

    get cancellationTabLabel() {
        return 'Cancellation Alerts (' + this.cancellationAlerts.length + ')';
    }

    get jeopardyTabLabel() {
        return 'In Jeopardy Alerts (' + this.jeopardyAlerts.length + ')';
    }

    get priorityEmptyMessage() {
        return this.emptyMessage(this.showPriorityTodayOnly, 'priority');
    }

    get panicEmptyMessage() {
        return this.emptyMessage(this.showPanicTodayOnly, 'panic');
    }

    get cancellationEmptyMessage() {
        return this.emptyMessage(this.showCancellationTodayOnly, 'cancellation');
    }

    get jeopardyEmptyMessage() {
        return this.emptyMessage(this.showJeopardyTodayOnly, 'in jeopardy');
    }

    get todayOnlyHelpText() {
        return 'Uncheck to show all alerts. Check to show only today\'s alerts.';
    }

    firstEnabledTab() {
        if (this.priorityAlertsEnabled) {
            return 'jobs';
        }
        if (this.cancellationAlertsEnabled) {
            return 'cancellation';
        }
        if (this.jeopardyAlertsEnabled) {
            return 'jeopardy';
        }
        if (this.panicAlertsEnabled) {
            return 'panic';
        }
        return 'jobs';
    }

    alertsOfType(alertType, todayOnly) {
        const typed = (this.allAlerts || []).filter((alert) => alert.alertType === alertType);
        if (!todayOnly) {
            return typed;
        }
        return typed.filter((alert) => this.isCreatedToday(alert.createdDate));
    }

    emptyMessage(todayOnly, noun) {
        if (todayOnly) {
            return 'No ' + noun + ' alerts for today.';
        }
        return 'No ' + noun + ' alerts match your loaded filters.';
    }

    isCreatedToday(value) {
        if (!value) {
            return false;
        }
        const created = new Date(value);
        if (Number.isNaN(created.getTime())) {
            return false;
        }
        const now = new Date();
        return created.getFullYear() === now.getFullYear()
            && created.getMonth() === now.getMonth()
            && created.getDate() === now.getDate();
    }

    toggleCommunityPanel() {
        this.isCommunityPanelOpen = !this.isCommunityPanelOpen;
    }

    handleTabActive(event) {
        const nextTab = event.target.value;
        if (nextTab) {
            this.activeTab = nextTab;
        }
    }

    handleRefresh() {
        this.loadAlerts(false);
        this.showToast('Synced', 'Territory filters updated', 'success', 'pester');
    }

    handleTodayOnlyChange(event) {
        const alertType = this.resolveAlertType(event);
        let checked = event.target.checked === true;
        if (event.detail && typeof event.detail.checked === 'boolean') {
            checked = event.detail.checked;
        }
        if (alertType === ALERT_TYPE_PANIC) {
            this.showPanicTodayOnly = checked;
        } else if (alertType === ALERT_TYPE_JOB) {
            this.showPriorityTodayOnly = checked;
        } else if (alertType === ALERT_TYPE_CANCELLATION) {
            this.showCancellationTodayOnly = checked;
        } else if (alertType === ALERT_TYPE_JEOPARDY) {
            this.showJeopardyTodayOnly = checked;
        }
        this.updateUtilityBar(false);
    }

    mapAlertRecord(record) {
        const sa = record.Service_Appointment__r || {};
        const resource = record.Panic_Service_Resource__r || {};
        const addressParts = [];
        if (sa.Street) {
            addressParts.push(sa.Street);
        }
        if (sa.City) {
            addressParts.push(sa.City);
        }
        const latitude = record.Last_Known_Latitude__c;
        const longitude = record.Last_Known_Longitude__c;
        const hasLocation = latitude != null && longitude != null;
        const relatedUser = resource.RelatedRecord || {};
        const phone = relatedUser.Phone;
        const employeeNumber = relatedUser.EmployeeNumber;
        const natureOfEmergency = record.Nature_of_the_Emergency__c;
        return {
            ...record,
            alertType: record.Alert_Type__c,
            saId: record.Service_Appointment__c,
            saNumber: sa.AppointmentNumber,
            resourceId: record.Panic_Service_Resource__c,
            resourceName: resource.Name,
            phone,
            employeeNumber,
            natureOfEmergency,
            hasPhone: this.hasText(phone),
            hasEmployeeNumber: this.hasText(employeeNumber),
            hasNature: this.hasText(natureOfEmergency),
            priority: sa.Priority__c || 'N/A',
            saStatus: sa.Status || 'N/A',
            inJeopardyLabel: sa.FSL__InJeopardy__c === true ? 'Yes' : 'No',
            earlyStart: sa.EarliestStartTime,
            dueDate: sa.DueDate,
            address: addressParts.length > 0 ? addressParts.join(', ') : 'No Address Provided',
            territoryName: record.Service_Territory__r ? record.Service_Territory__r.Name : 'Unknown',
            createdDate: record.CreatedDate,
            isAcknowledged: record.Status__c === 'Acknowledged',
            latitude,
            longitude,
            hasLocation,
            mapUrl: this.buildMapUrl(latitude, longitude)
        };
    }

    hasText(value) {
        return value != null && String(value).trim() !== '';
    }

    buildMapUrl(latitude, longitude) {
        if (latitude == null || longitude == null) {
            return null;
        }
        return 'https://www.google.com/maps?q=' + latitude + ',' + longitude;
    }

    loadAlerts(isNewAlertEvent) {
        const oldAlertIds = new Set(this.allAlerts.map((alert) => alert.Id));
        const currentTimestamp = new Date().getTime().toString();

        getActiveAlerts({ cacheBuster: currentTimestamp })
            .then((result) => {
                this.allAlerts = (result || []).map((record) => this.mapAlertRecord(record));
                const hasNewRelevantAlert = isNewAlertEvent ? this.notifyNewAlerts(oldAlertIds) : false;
                this.updateUtilityBar(hasNewRelevantAlert);
            })
            .catch(() => {
                this.allAlerts = [];
                this.updateUtilityBar(false);
            });
    }

    notifyNewAlerts(oldAlertIds) {
        const newAlerts = [];
        const enabled = this.visibleEnabledAlerts();
        for (let i = 0; i < enabled.length; i++) {
            if (!oldAlertIds.has(enabled[i].Id)) {
                newAlerts.push(enabled[i]);
            }
        }
        if (newAlerts.length === 0) {
            return false;
        }
        const hasPanic = newAlerts.some((alert) => alert.alertType === ALERT_TYPE_PANIC);
        if (hasPanic) {
            this.showToast('New Panic Alert', 'A field resource in your territory has triggered a panic alert.', 'error', 'sticky');
        } else if (newAlerts.some((alert) => alert.alertType === ALERT_TYPE_CANCELLATION)) {
            this.showToast('New Cancellation Alert', 'A service appointment in your territory was canceled.', 'error', 'sticky');
        } else if (newAlerts.some((alert) => alert.alertType === ALERT_TYPE_JEOPARDY)) {
            this.showToast('New In Jeopardy Alert', 'A service appointment in your territory is in jeopardy.', 'warning', 'sticky');
        } else {
            this.showToast('New High Priority Job', 'A new high-priority job has been assigned to your Territory.', 'warning', 'sticky');
        }
        if (this.isCommunityMode) {
            this.isCommunityPanelOpen = true;
        }
        return true;
    }

    visibleEnabledAlerts() {
        const records = [];
        if (this.priorityAlertsEnabled) {
            records.push(...this.jobAlerts);
        }
        if (this.panicAlertsEnabled) {
            records.push(...this.panicAlerts);
        }
        if (this.cancellationAlertsEnabled) {
            records.push(...this.cancellationAlerts);
        }
        if (this.jeopardyAlertsEnabled) {
            records.push(...this.jeopardyAlerts);
        }
        return records;
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
        } catch {
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
        const alertRecord = this.allAlerts.find((alert) => alert.saId === recordId);
        const saNumber = alertRecord ? alertRecord.saNumber : 'Selected SA';

        createTemporaryGanttFilter({ saId: recordId, saNumber: saNumber })
            .then((result) => {
                if (result === 'Success') {
                    this.showToast('Gantt Filter Applied', `Appointment list updated to show ${saNumber}`, 'success', 'dismissible');
                } else {
                    this.showToast('Warning', result, 'warning', 'dismissible');
                }
            })
            .catch(() => {
                this.showToast('Error', 'Failed to update Gantt view.', 'error', 'dismissible');
            });
    }

    resolveAlertType(event) {
        const dataset = event && event.currentTarget ? event.currentTarget.dataset : null;
        if (!dataset || !dataset.alertType) {
            return null;
        }
        return dataset.alertType;
    }

    alertsForType(alertType) {
        if (alertType === ALERT_TYPE_PANIC) {
            return this.panicAlerts;
        }
        if (alertType === ALERT_TYPE_JOB) {
            return this.jobAlerts;
        }
        if (alertType === ALERT_TYPE_CANCELLATION) {
            return this.cancellationAlerts;
        }
        if (alertType === ALERT_TYPE_JEOPARDY) {
            return this.jeopardyAlerts;
        }
        return [];
    }

    restoreLabelForType(alertType) {
        if (alertType === ALERT_TYPE_PANIC) {
            return 'panic alerts';
        }
        if (alertType === ALERT_TYPE_CANCELLATION) {
            return 'cancellation alerts';
        }
        if (alertType === ALERT_TYPE_JEOPARDY) {
            return 'in jeopardy alerts';
        }
        return 'priority alerts';
    }

    handleUndoDismissAll(event) {
        const alertType = this.resolveAlertType(event);
        if (!alertType) {
            return;
        }
        const restoredLabel = this.restoreLabelForType(alertType);
        undoAllDismissals({ alertType: alertType })
            .then(() => {
                this.showToast('Restored', 'Previously dismissed ' + restoredLabel + ' have been restored.', 'success', 'dismissible');
                this.loadAlerts(false);
            })
            .catch(() => {
                this.showToast('Error', 'Failed to restore alerts.', 'error', 'dismissible');
            });
    }

    updateUtilityBar(hasNewRelevantAlert) {
        if (!this.utilityId || !this.isUtilityBarContext) {
            if (hasNewRelevantAlert) {
                this.playBuzzer();
            }
            return;
        }

        const count = this.combinedCount;
        const newLabel = count > 0 ? `Alert Center (${count})` : 'Alert Center';
        const shouldHighlight = Boolean(hasNewRelevantAlert);

        updateUtility(this.utilityId, { label: newLabel, highlighted: shouldHighlight }).catch(() => {
            return;
        });
        updatePanel(this.utilityId, { label: newLabel }).catch(() => {
            return;
        });

        if (shouldHighlight) {
            this.playBuzzer();
        }
    }

    playBuzzer() {
        try {
            const audioEl = this.template.querySelector('.alert-buzzer');
            if (audioEl) {
                audioEl.play().catch(() => {
                    return;
                });
            }
        } catch {
            return;
        }
    }

    handleAcknowledge(event) {
        const alertId = event.target.dataset.id;
        acknowledgeAlert({ alertId: alertId })
            .then(() => {
                this.showToast('Success', 'Alert Acknowledged Globally', 'success', 'dismissible');
                this.loadAlerts(false);
            })
            .catch(() => {
                this.showToast('Error', 'Failed to acknowledge alert.', 'error', 'dismissible');
            });
    }

    handleDismiss(event) {
        const alertId = event.target.dataset.id;
        dismissAlert({ alertId: alertId })
            .then(() => {
                this.allAlerts = this.allAlerts.filter((alert) => alert.Id !== alertId);
                this.updateUtilityBar(false);
            })
            .catch(() => {
                this.showToast('Error', 'Failed to dismiss alert.', 'error', 'dismissible');
            });
    }

    handleDismissAll(event) {
        const alertType = this.resolveAlertType(event);
        const sourceAlerts = this.alertsForType(alertType);
        if (!sourceAlerts || sourceAlerts.length === 0) {
            return;
        }

        const alertsToDismiss = sourceAlerts.filter((alert) => !alert.isAcknowledged);
        if (alertsToDismiss.length === 0) {
            this.showToast('Info', 'No new alerts to dismiss.', 'info', 'dismissible');
            return;
        }

        const alertIds = alertsToDismiss.map((alert) => alert.Id);
        dismissAllAlerts({ alertIds: alertIds })
            .then(() => {
                this.allAlerts = this.allAlerts.filter((alert) => !alertIds.includes(alert.Id));
                this.updateUtilityBar(false);
            })
            .catch(() => {
                this.showToast('Error', 'Failed to dismiss alerts.', 'error', 'dismissible');
            });
    }

    handleSubscribe() {
        const messageCallback = (response) => {
            const changeType = response.data?.payload?.ChangeEventHeader?.changeType;
            if (changeType === 'CREATE') {
                this.loadAlerts(true);
            } else if (changeType === 'UPDATE') {
                this.loadAlerts(false);
            }
        };

        subscribe(this.channelName, -1, messageCallback)
            .then((response) => {
                this.subscription = response;
            })
            .catch(() => {
                return;
            });
    }

    startSmartPolling() {
        this.pollingInterval = setInterval(() => {
            this.loadAlerts(true);
        }, 20000);
    }

    handleUnsubscribe() {
        unsubscribe(this.subscription, () => {
            return;
        });
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