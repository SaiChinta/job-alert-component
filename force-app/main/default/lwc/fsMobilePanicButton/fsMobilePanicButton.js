import { LightningElement, track, wire } from 'lwc';
import { gql, graphql } from 'lightning/uiGraphQLApi';
import { createRecord } from 'lightning/uiRecordApi';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getLocationService } from 'lightning/mobileCapabilities';
import userId from '@salesforce/user/Id';
import ALERT_CENTER_OBJECT from '@salesforce/schema/FS_AlertCenter__c';
import NATURE_FIELD from '@salesforce/schema/FS_AlertCenter__c.Nature_of_the_Emergency__c';

const SHOW_TERRITORY_DIAGNOSTICS = false;

const SERVICE_RESOURCE_QUERY = gql`
    query getCurrentUserServiceResource($userId: ID) {
        uiapi {
            query {
                ServiceResource(where: { RelatedRecordId: { eq: $userId } }, first: 1) {
                    edges {
                        node {
                            Id
                        }
                    }
                }
            }
        }
    }
`;

const TERRITORY_MEMBER_QUERY = gql`
    query getCurrentUserTerritoryMembers($userId: ID) {
        uiapi {
            query {
                ServiceTerritoryMember(
                    where: { ServiceResource: { RelatedRecordId: { eq: $userId } } }
                    first: 20
                ) {
                    edges {
                        node {
                            Id
                            TerritoryType {
                                value
                                displayValue
                            }
                            ServiceTerritoryId {
                                value
                                displayValue
                            }
                            ServiceResourceId {
                                value
                            }
                        }
                    }
                }
            }
        }
    }
`;

const FALLBACK_NATURE_OPTIONS = [
    { label: 'Medical crisis', value: 'Medical crisis' },
    { label: 'Physical assault', value: 'Physical assault' },
    { label: 'Threat of violence', value: 'Threat of violence' },
    { label: 'Environmental accident', value: 'Environmental accident' }
];

export default class FsMobilePanicButton extends LightningElement {
    currentUserId = userId;
    serviceResourceId;
    territoryMemberEdges = [];
    locationService;
    resourceQueryError = '';
    territoryQueryError = '';
    lastCreateResult = '';

    @track isLoading = false;
    @track isEmergencyTriggered = false;
    @track statusMessage = '';
    @track latitude = null;
    @track longitude = null;
    @track selectedNature = '';
    @track schemaNatureOptions = [];

    connectedCallback() {
        try {
            this.locationService = getLocationService();
        } catch {
            this.locationService = null;
        }
    }

    get showTerritoryDiagnostics() {
        return SHOW_TERRITORY_DIAGNOSTICS;
    }

    get natureRecordTypeId() {
        if (
            this.alertCenterObjectInfo &&
            this.alertCenterObjectInfo.data &&
            this.alertCenterObjectInfo.data.defaultRecordTypeId
        ) {
            return this.alertCenterObjectInfo.data.defaultRecordTypeId;
        }
        return undefined;
    }

    get natureOptions() {
        if (this.schemaNatureOptions && this.schemaNatureOptions.length > 0) {
            return this.schemaNatureOptions;
        }
        return FALLBACK_NATURE_OPTIONS;
    }

    get resourceVariables() {
        return {
            userId: this.currentUserId
        };
    }

    get isNativeLocationAvailable() {
        return this.locationService && typeof this.locationService.isAvailable === 'function' && this.locationService.isAvailable();
    }

    get territoryDiagnosticsText() {
        const lines = this.buildTerritoryDiagnosticLines();
        const texts = [];
        for (let i = 0; i < lines.length; i++) {
            texts.push(lines[i].text);
        }
        return texts.join('\n');
    }

    @wire(getObjectInfo, { objectApiName: ALERT_CENTER_OBJECT })
    alertCenterObjectInfo;

    @wire(getPicklistValues, {
        recordTypeId: '$natureRecordTypeId',
        fieldApiName: NATURE_FIELD
    })
    wiredNaturePicklist({ data, error }) {
        if (error || !data || !data.values || data.values.length === 0) {
            this.schemaNatureOptions = [];
            return;
        }
        this.schemaNatureOptions = data.values.map((item) => ({
            label: item.label,
            value: item.value
        }));
    }

    @wire(graphql, {
        query: SERVICE_RESOURCE_QUERY,
        variables: '$resourceVariables'
    })
    wiredServiceResource(result) {
        this.resourceQueryError = this.formatGraphqlErrors(result);
        const data = result && result.data;
        if (!data) {
            this.serviceResourceId = undefined;
            return;
        }
        const edges = data.uiapi?.query?.ServiceResource?.edges || [];
        this.serviceResourceId = edges.length > 0 ? edges[0].node.Id : undefined;
    }

    @wire(graphql, {
        query: TERRITORY_MEMBER_QUERY,
        variables: '$resourceVariables'
    })
    wiredTerritoryMembers(result) {
        this.territoryQueryError = this.formatGraphqlErrors(result);
        const data = result && result.data;
        if (!data) {
            this.territoryMemberEdges = [];
            return;
        }
        this.territoryMemberEdges = data.uiapi?.query?.ServiceTerritoryMember?.edges || [];
    }

    handleNatureChange(event) {
        this.selectedNature = event.detail.value;
    }

    handleSOSClick() {
        this.isLoading = true;
        this.statusMessage = 'Fetching device GPS coordinates...';
        this.captureDeviceLocation()
            .then((coords) => {
                this.latitude = coords.latitude;
                this.longitude = coords.longitude;
                this.sendAlertToDispatcher();
            })
            .catch((error) => {
                this.handleLocationError(error);
            });
    }

    captureDeviceLocation() {
        if (this.isNativeLocationAvailable) {
            return this.locationService
                .getCurrentPosition({ enableHighAccuracy: true })
                .then((position) => this.coordsFromPosition(position));
        }
        return this.captureBrowserLocation();
    }

    captureBrowserLocation() {
        return new Promise((resolve, reject) => {
            if (!navigator.geolocation) {
                reject({
                    code: 'UNSUPPORTED',
                    message: 'Geolocation is not supported on this device.'
                });
                return;
            }
            navigator.geolocation.getCurrentPosition(
                (position) => {
                    resolve(this.coordsFromPosition(position));
                },
                (error) => {
                    reject(error);
                },
                {
                    enableHighAccuracy: true,
                    timeout: 10000,
                    maximumAge: 0
                }
            );
        });
    }

    coordsFromPosition(position) {
        const coords = position && position.coords ? position.coords : {};
        return {
            latitude: coords.latitude,
            longitude: coords.longitude
        };
    }

    sendAlertToDispatcher() {
        this.statusMessage = 'Dispatching Emergency SOS Alert...';
        if (!this.serviceResourceId) {
            this.lastCreateResult = 'Last create: blocked, no Service Resource.';
            this.showToast('Alert Error', 'No Service Resource is linked to the current user.', 'error');
            this.isLoading = false;
            return;
        }

        const fields = this.buildAlertFields();
        this.lastCreateResult = this.describeCreatePayload(fields);

        createRecord({
            apiName: 'FS_AlertCenter__c',
            fields: fields
        })
            .then(() => {
                this.isEmergencyTriggered = true;
                this.showToast('SOS Sent', 'Dispatcher alert dispatched successfully.', 'success');
            })
            .catch((err) => {
                this.lastCreateResult = this.lastCreateResult + ' Create failed: ' + this.getErrorMessage(err);
                this.showToast('System Fault', this.getErrorMessage(err), 'error');
            })
            .finally(() => {
                this.isLoading = false;
            });
    }

    buildAlertFields() {
        const fields = {
            Alert_Type__c: 'Panic Alert',
            Status__c: 'New',
            Panic_Service_Resource__c: this.serviceResourceId,
            Last_Known_Latitude__c: this.latitude,
            Last_Known_Longitude__c: this.longitude
        };
        const territoryId = this.resolvePrimaryTerritoryId();
        if (territoryId) {
            fields.Service_Territory__c = territoryId;
        }
        if (this.selectedNature) {
            fields.Nature_of_the_Emergency__c = this.selectedNature;
        }
        return fields;
    }

    resolvePrimaryTerritoryId() {
        const edges = this.territoryMemberEdges || [];
        for (let i = 0; i < edges.length; i++) {
            const node = edges[i] && edges[i].node ? edges[i].node : null;
            if (!node) {
                continue;
            }
            const typeValue = this.readFieldValue(node.TerritoryType);
            if (typeValue !== 'P' && typeValue !== 'Primary') {
                continue;
            }
            const lookupId = this.readFieldValue(node.ServiceTerritoryId);
            if (lookupId) {
                return lookupId;
            }
            const relatedId = this.readRelatedRecordId(node.ServiceTerritory);
            if (relatedId) {
                return relatedId;
            }
        }
        return null;
    }

    buildTerritoryDiagnosticLines() {
        const lines = [];
        this.addDiagnosticLine(lines, 'User: ' + this.displayOrBlank(this.currentUserId));
        this.addDiagnosticLine(lines, 'Service Resource: ' + this.displayOrBlank(this.serviceResourceId));
        this.addDiagnosticLine(lines, 'STM query: static by user');
        if (this.resourceQueryError) {
            this.addDiagnosticLine(lines, 'SR GraphQL: ' + this.resourceQueryError);
        }
        if (this.territoryQueryError) {
            this.addDiagnosticLine(lines, 'STM GraphQL: ' + this.territoryQueryError);
        }
        const edges = this.territoryMemberEdges || [];
        this.addDiagnosticLine(lines, 'STM rows: ' + edges.length);
        const summaries = this.summarizeTerritoryMembers();
        for (let i = 0; i < summaries.length; i++) {
            this.addDiagnosticLine(lines, summaries[i]);
        }
        const resolved = this.resolvePrimaryTerritoryId();
        this.addDiagnosticLine(lines, 'Resolved territory: ' + this.displayOrBlank(resolved));
        this.addDiagnosticLine(
            lines,
            'Create will set Service_Territory__c: ' + (resolved ? 'yes' : 'no')
        );
        if (this.lastCreateResult) {
            this.addDiagnosticLine(lines, this.lastCreateResult);
        }
        return lines;
    }

    addDiagnosticLine(lines, text) {
        lines.push({
            key: String(lines.length + 1),
            text: text
        });
    }

    summarizeTerritoryMembers() {
        const edges = this.territoryMemberEdges || [];
        const lines = [];
        for (let i = 0; i < edges.length; i++) {
            lines.push(this.summarizeTerritoryMemberRow(i, edges[i]));
        }
        return lines;
    }

    summarizeTerritoryMemberRow(index, edge) {
        const node = edge && edge.node ? edge.node : null;
        if (!node) {
            return index + 1 + '. (empty node)';
        }
        const typeValue = this.readFieldValue(node.TerritoryType);
        const typeLabel = node.TerritoryType && node.TerritoryType.displayValue
            ? String(node.TerritoryType.displayValue)
            : '';
        const lookupId = this.readFieldValue(node.ServiceTerritoryId);
        const lookupLabel = node.ServiceTerritoryId && node.ServiceTerritoryId.displayValue
            ? String(node.ServiceTerritoryId.displayValue)
            : '';
        const relatedId = this.readRelatedRecordId(node.ServiceTerritory);
        const relatedName = node.ServiceTerritory ? this.readFieldValue(node.ServiceTerritory.Name) : '';
        const relatedResourceId = this.readFieldValue(node.ServiceResourceId);
        return (
            index +
            1 +
            '. type=' +
            this.displayOrBlank(typeValue) +
            (typeLabel ? ' (' + typeLabel + ')' : '') +
            ' lookup=' +
            this.displayOrBlank(lookupId) +
            (lookupLabel ? ' lookupLabel=' + lookupLabel : '') +
            ' related=' +
            this.displayOrBlank(relatedId) +
            (relatedName ? ' name=' + relatedName : '') +
            (relatedResourceId ? ' sr=' + relatedResourceId : '')
        );
    }

    describeCreatePayload(fields) {
        const territoryId = fields.Service_Territory__c;
        if (territoryId) {
            return 'Last create payload territory: ' + territoryId;
        }
        return 'Last create payload territory: omitted';
    }

    readFieldValue(field) {
        if (field === null || field === undefined) {
            return '';
        }
        if (typeof field === 'string' || typeof field === 'number') {
            return String(field);
        }
        if (typeof field === 'object' && field.value !== undefined && field.value !== null && field.value !== '') {
            return String(field.value);
        }
        return '';
    }

    readRelatedRecordId(related) {
        if (!related) {
            return '';
        }
        if (typeof related.Id === 'string') {
            return related.Id;
        }
        return this.readFieldValue(related.Id);
    }

    displayOrBlank(value) {
        if (value === null || value === undefined || value === '') {
            return '(blank)';
        }
        return String(value);
    }

    formatGraphqlErrors(result) {
        if (!result) {
            return '';
        }
        const rawErrors = result.errors || result.error;
        if (!rawErrors) {
            return '';
        }
        const list = Array.isArray(rawErrors) ? rawErrors : [rawErrors];
        const messages = [];
        for (let i = 0; i < list.length; i++) {
            const message = this.readGraphqlErrorMessage(list[i]);
            if (message) {
                messages.push(message);
            }
        }
        return messages.join(' | ');
    }

    readGraphqlErrorMessage(item) {
        if (!item) {
            return '';
        }
        if (typeof item === 'string') {
            return item;
        }
        if (item.message) {
            return String(item.message);
        }
        if (item.body && item.body.message) {
            return String(item.body.message);
        }
        return '';
    }

    getErrorMessage(error) {
        if (error?.body?.message) {
            return error.body.message;
        }
        if (Array.isArray(error?.body)) {
            return error.body.map((item) => item.message).join(', ');
        }
        if (error?.message) {
            return error.message;
        }
        return 'Unable to create the panic alert.';
    }

    handleLocationError(error) {
        this.isLoading = false;
        const code = error && error.code;
        let msg = 'Failed to capture GPS location.';
        if (code === 'USER_DENIED_PERMISSION' || code === 'LOCATION_SERVICE_DISABLED' || code === 1) {
            msg = 'Location access denied. Enable Location for the Field Service app in device Settings.';
        } else if (code === 'POSITION_UNAVAILABLE' || code === 2) {
            msg = 'Location information is unavailable.';
        } else if (code === 'TIMEOUT' || code === 3) {
            msg = 'GPS location request timed out.';
        } else if (code === 'UNSUPPORTED') {
            msg = error.message || msg;
        }
        this.showToast('GPS Error', msg, 'error');
    }

    showToast(title, message, variant) {
        this.dispatchEvent(
            new ShowToastEvent({
                title: title,
                message: message,
                variant: variant
            })
        );
    }
}
