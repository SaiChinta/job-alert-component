import { LightningElement, track, wire } from 'lwc';
import { gql, graphql } from 'lightning/uiGraphQLApi';
import { createRecord } from 'lightning/uiRecordApi';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { getLocationService } from 'lightning/mobileCapabilities';
import userId from '@salesforce/user/Id';

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
    query getServiceResourceTerritories($resourceId: ID) {
        uiapi {
            query {
                ServiceTerritoryMember(
                    where: { ServiceResourceId: { eq: $resourceId } }
                    first: 20
                ) {
                    edges {
                        node {
                            Id
                            TerritoryType {
                                value
                            }
                            ServiceTerritoryId {
                                value
                            }
                        }
                    }
                }
            }
        }
    }
`;

export default class FsMobilePanicButton extends LightningElement {
    currentUserId = userId;
    serviceResourceId;
    territoryMemberEdges = [];
    locationService;

    @track isLoading = false;
    @track isEmergencyTriggered = false;
    @track statusMessage = '';
    @track latitude = null;
    @track longitude = null;
    @track selectedNature = '';

    connectedCallback() {
        try {
            this.locationService = getLocationService();
        } catch {
            this.locationService = null;
        }
    }

    get natureOptions() {
        return [
            { label: 'Medical crisis', value: 'Medical crisis' },
            { label: 'Physical assault', value: 'Physical assault' },
            { label: 'Threat of violence', value: 'Threat of violence' },
            { label: 'Environmental accident', value: 'Environmental accident' }
        ];
    }

    get resourceVariables() {
        return {
            userId: this.currentUserId
        };
    }

    get territoryQuery() {
        return this.serviceResourceId ? TERRITORY_MEMBER_QUERY : undefined;
    }

    get territoryVariables() {
        return {
            resourceId: this.serviceResourceId
        };
    }

    get isNativeLocationAvailable() {
        return this.locationService && typeof this.locationService.isAvailable === 'function' && this.locationService.isAvailable();
    }

    @wire(graphql, {
        query: SERVICE_RESOURCE_QUERY,
        variables: '$resourceVariables'
    })
    wiredServiceResource(result) {
        const { data, errors } = result;
        if (errors || !data) {
            this.serviceResourceId = undefined;
            return;
        }
        const edges = data.uiapi?.query?.ServiceResource?.edges || [];
        this.serviceResourceId = edges.length > 0 ? edges[0].node.Id : undefined;
    }

    @wire(graphql, {
        query: '$territoryQuery',
        variables: '$territoryVariables'
    })
    wiredTerritoryMembers(result) {
        const { data, errors } = result;
        if (errors || !data) {
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
            this.showToast('Alert Error', 'No Service Resource is linked to the current user.', 'error');
            this.isLoading = false;
            return;
        }

        createRecord({
            apiName: 'FS_AlertCenter__c',
            fields: this.buildAlertFields()
        })
            .then(() => {
                this.isEmergencyTriggered = true;
                this.showToast('SOS Sent', 'Dispatcher alert dispatched successfully.', 'success');
            })
            .catch((err) => {
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
            const typeValue = edges[i]?.node?.TerritoryType?.value;
            if (typeValue === 'P' || typeValue === 'Primary') {
                return edges[i]?.node?.ServiceTerritoryId?.value || null;
            }
        }
        return null;
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
