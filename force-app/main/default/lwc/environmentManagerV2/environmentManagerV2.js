import { LightningElement, track } from 'lwc';

import getAuthorizationUrl  from '@salesforce/apex/EnvironmentManagerCtrl.getAuthorizationUrl';
import exchangeCodeAndSave  from '@salesforce/apex/EnvironmentManagerCtrl.exchangeCodeAndSave';
import getSavedEnvironments from '@salesforce/apex/EnvironmentManagerCtrl.getSavedEnvironments';
import deleteEnvironmentApex from '@salesforce/apex/EnvironmentManagerCtrl.deleteEnvironment';

const POPUP_WIDTH  = 600;
const POPUP_HEIGHT = 700;

export default class environmentManagerV2 extends LightningElement {

    @track newEnvName           = '';
    @track newOrgType           = 'production';
    @track isConnecting         = false;
    @track connectingMessage    = '';
    @track connectStatusMessage = '';
    @track connectStatusClass   = 'status-success';
    @track savedEnvironments    = [];
    @track isLoadingEnvironments = false;

    _oauthPopup      = null;
    _pendingState    = null;
    _pendingOrgType  = null;
    _pendingEnvName  = null;
    _messageListener = null;
    _popupTimer      = null;

    get orgTypeOptions() {
        return [
            { label: 'Production', value: 'production' },
            { label: 'Sandbox',    value: 'sandbox'    }
        ];
    }

    get hasSavedEnvironments() {
        return this.savedEnvironments.length > 0;
    }

    get isConnectDisabled() {
        return this.isConnecting || !this.newEnvName.trim();
    }

    connectedCallback() {
        this.loadSavedEnvironments();
    }

    disconnectedCallback() {
        this._cleanup();
    }

    handleEnvNameChange(event) {
        this.newEnvName = event.detail.value;
    }

    handleOrgTypeChange(event) {
        this.newOrgType = event.detail.value;
    }

    async initiateOAuth() {
        const envName = this.newEnvName.trim();
        if (!envName) {
            this._setStatus('Please enter an Environment Name.', false);
            return;
        }

        this.isConnecting         = true;
        this.connectStatusMessage = '';
        this.connectingMessage    = 'Opening Salesforce login...';

        try {
            const stateToken     = this._generateStateToken();
            this._pendingState   = stateToken;
            this._pendingOrgType = this.newOrgType;
            this._pendingEnvName = envName;

            const authUrl = await getAuthorizationUrl({
                orgType    : this.newOrgType,
                stateToken : stateToken,
                environmentName: envName  
            });

            const left     = Math.round((screen.width  - POPUP_WIDTH)  / 2);
            const top      = Math.round((screen.height - POPUP_HEIGHT) / 2);
            const features = `width=${POPUP_WIDTH},height=${POPUP_HEIGHT},left=${left},top=${top},toolbar=no,menubar=no,scrollbars=yes,resizable=yes`;

            this._oauthPopup = window.open(authUrl, 'SalesforceOAuth', features);

            if (!this._oauthPopup || this._oauthPopup.closed) {
                throw new Error('Popup blocked. Please allow popups for this site.');
            }

            this.connectingMessage = 'Waiting for you to log in...';
            this._attachMessageListener();      
            this._startPopupMonitor();

        } catch (e) {
            this.isConnecting = false;
            this._setStatus('Error: ' + (e?.body?.message || e?.message || String(e)), false);
            this._cleanup();
        }
    }

    // Monitor popup — if user closes it manually, stop waiting
    _startPopupMonitor() {
        this._popupTimer = setInterval(() => {
            if (this._oauthPopup && this._oauthPopup.closed) {
                clearInterval(this._popupTimer);
                this._popupTimer = null;
                if (this.isConnecting) {
                    this.isConnecting      = false;
                    this.connectingMessage = '';
                    this._removeMessageListener();
                    this._setStatus('Login window was closed. Please try again.', false);
                }
            }
        }, 500);
    }

    _attachMessageListener() {
        this._removeMessageListener();
        this._messageListener = this._handleOAuthMessage.bind(this);
        window.addEventListener('message', this._messageListener);
    }

    _removeMessageListener() {
        if (this._messageListener) {
            window.removeEventListener('message', this._messageListener);
            this._messageListener = null;
        }
    }

    async _handleOAuthMessage(event) {
        const data = event.data;

        
        if (!data || data.type !== 'SF_OAUTH_CALLBACK') return;

        this._removeMessageListener();

        if (this._popupTimer) {
            clearInterval(this._popupTimer);
            this._popupTimer = null;
        }

        if (!data.success) {
            this.isConnecting = false;
            this._setStatus('Authentication failed: ' + (data.message || data.error), false);
            return;
        }

        if (data.state !== this._pendingState) {
            this.isConnecting = false;
            this._setStatus('Security check failed. Please try again.', false);
            return;
        }

        this.connectingMessage = 'Completing authentication...';

        try {
            const result = await exchangeCodeAndSave({
                authCode        : data.code,
                orgType         : this._pendingOrgType,
                environmentName : this._pendingEnvName
            });

            this.isConnecting = false;
            this._setStatus(result.message, true);
            this.newEnvName = '';
            this.newOrgType = 'production';
            await this.loadSavedEnvironments();

        } catch (e) {
            this.isConnecting = false;
            this._setStatus(e?.body?.message || e?.message || String(e), false);
        } finally {
            this._pendingState   = null;
            this._pendingOrgType = null;
            this._pendingEnvName = null;
        }
    }

    async reconnectEnvironment(event) {
        const name    = event.currentTarget.dataset.name;
        const orgType = event.currentTarget.dataset.type;
        this.newEnvName = name;
        this.newOrgType = (orgType === 'Sandbox') ? 'sandbox' : 'production';
        await this.initiateOAuth();
    }

    async deleteEnvironment(event) {
        const envId = event.currentTarget.dataset.id;
        const env   = this.savedEnvironments.find(e => e.Id === envId);
        if (!window.confirm(
            `Delete environment "${env ? env.Name : ''}"?\n\nThis will remove the stored credentials.`
        )) return;
        try {
            await deleteEnvironmentApex({ environmentId: envId });
            this._setStatus('Environment deleted successfully.', true);
            await this.loadSavedEnvironments();
        } catch (e) {
            this._setStatus('Delete failed: ' + (e?.body?.message || e?.message || String(e)), false);
        }
    }

    async loadSavedEnvironments() {
    this.isLoadingEnvironments = true;
    try {
        const raw = await getSavedEnvironments();
        this.savedEnvironments = raw.map(env => ({
            ...env,
            orgTypeBadgeClass : env.Org_Type__c === 'Production'
                ? 'slds-badge slds-theme_success'
                : 'slds-badge',
            statusBadgeClass  : env.Connection_Status__c === 'Connected'
                ? 'slds-badge slds-theme_success'
                : env.Connection_Status__c === 'Disconnected'
                    ? 'slds-badge slds-theme_error'
                    : 'slds-badge',
            lastModifiedFormatted: new Date(env.LastModifiedDate).toLocaleDateString()
        }));
    } catch (e) {
        this._setStatus('Could not load environments: ' + (e?.body?.message || e?.message || String(e)), false);
    } finally {
        this.isLoadingEnvironments = false;
    }
}

    _setStatus(message, isSuccess) {
        this.connectStatusMessage = message;
        this.connectStatusClass   = isSuccess ? 'status-success' : 'status-error';
    }

    _generateStateToken() {
        const arr = new Uint8Array(16);
        crypto.getRandomValues(arr);
        return Array.from(arr, b => b.toString(16).padStart(2, '0')).join('');
    }

    _cleanup() {
        this._removeMessageListener();
        if (this._popupTimer) {
            clearInterval(this._popupTimer);
            this._popupTimer = null;
        }
    }
}