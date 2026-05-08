import { LightningElement, track } from 'lwc';

import getAuthorizationUrl   from '@salesforce/apex/GitHubManagerCtrl.getAuthorizationUrl';
import exchangeCodeAndSave   from '@salesforce/apex/GitHubManagerCtrl.exchangeCodeAndSave';
import getSavedConnections   from '@salesforce/apex/GitHubManagerCtrl.getSavedConnections';
import deleteConnectionApex  from '@salesforce/apex/GitHubManagerCtrl.deleteConnection';
import verifyConnectionApex  from '@salesforce/apex/GitHubManagerCtrl.verifyConnection';

const POPUP_WIDTH  = 600;
const POPUP_HEIGHT = 700;

export default class gitHubManager extends LightningElement {

    @track connectionName       = '';
    @track repoOwner            = '';
    @track repoName             = '';
    @track isConnecting         = false;
    @track connectingMessage    = '';
    @track connectStatusMessage = '';
    @track connectStatusClass   = 'status-success';
    @track savedConnections     = [];
    @track isLoadingConnections = false;

    _oauthPopup      = null;
    _pendingState    = null;
    _pendingName     = null;
    _pendingOwner    = null;
    _pendingRepo     = null;
    _messageListener = null;
    _popupTimer      = null;

    get hasConnections() {
        return this.savedConnections.length > 0;
    }

    get isConnectDisabled() {
        return this.isConnecting         ||
               !this.connectionName.trim() ||
               !this.repoOwner.trim()      ||
               !this.repoName.trim();
    }

    connectedCallback() {
        this.loadSavedConnections();
    }

    disconnectedCallback() {
        this._cleanup();
    }

    handleConnectionNameChange(event) { this.connectionName = event.detail.value; }
    handleRepoOwnerChange(event)      { this.repoOwner      = event.detail.value; }
    handleRepoNameChange(event)       { this.repoName        = event.detail.value; }

    // ═══════════════════════════════════════════════════════════
    // Initiate OAuth — repoOwner se metadata config dhundega
    // ═══════════════════════════════════════════════════════════
    async initiateOAuth() {
        const name  = this.connectionName.trim();
        const owner = this.repoOwner.trim();
        const repo  = this.repoName.trim();

        if (owner.includes(' ') || repo.includes(' ')) {
            this._setStatus('Repo Owner and Repo Name cannot contain spaces.', false);
            return;
        }

        if (!name || !owner || !repo) {
            this._setStatus('Please fill all fields before connecting.', false);
            return;
        }

        this.isConnecting         = true;
        this.connectStatusMessage = '';
        this.connectingMessage    = 'Opening GitHub login...';

        try {
            const stateToken   = this._generateStateToken();
            this._pendingState = stateToken;
            this._pendingName  = name;
            this._pendingOwner = owner;
            this._pendingRepo  = repo;

            const authUrl = await getAuthorizationUrl({ stateToken });
            const left     = Math.round((screen.width  - POPUP_WIDTH)  / 2);
            const top      = Math.round((screen.height - POPUP_HEIGHT) / 2);
            const features = `width=${POPUP_WIDTH},height=${POPUP_HEIGHT},left=${left},top=${top},toolbar=no,menubar=no,scrollbars=yes,resizable=yes`;

            this._oauthPopup = window.open(authUrl, 'GitHubOAuth', features);

            if (!this._oauthPopup || this._oauthPopup.closed) {
                throw new Error('Popup blocked. Please allow popups for this site.');
            }

            this.connectingMessage = 'Waiting for GitHub login...';
            this._attachMessageListener();
            this._startPopupMonitor();

        } catch (e) {
            this.isConnecting = false;
            this._setStatus('Error: ' + (e?.body?.message || e?.message || String(e)), false);
            this._cleanup();
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Popup monitor
    // ═══════════════════════════════════════════════════════════
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

    // ═══════════════════════════════════════════════════════════
    // OAuth callback handler
    // ═══════════════════════════════════════════════════════════
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

        this.connectingMessage = 'Completing GitHub authentication...';

        try {
            // repoOwner already parameter mein hai — Apex same config use karega
            const result = await exchangeCodeAndSave({
                authCode       : data.code,
                connectionName : this._pendingName,
                repoOwner      : this._pendingOwner,
                repoName       : this._pendingRepo
            });

            this.isConnecting   = false;
            this._setStatus(result.message, true);
            this.connectionName = '';
            this.repoOwner      = '';
            this.repoName       = '';
            await this.loadSavedConnections();

        } catch (e) {
            this.isConnecting = false;
            this._setStatus(e?.body?.message || e?.message || String(e), false);
        } finally {
            this._pendingState = null;
            this._pendingName  = null;
            this._pendingOwner = null;
            this._pendingRepo  = null;
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Verify connection
    // ═══════════════════════════════════════════════════════════
    async verifyConnection(event) {
        const connId = event.currentTarget.dataset.id;
        try {
            const result = await verifyConnectionApex({ connectionId: connId });
            this._setStatus('✓ ' + result.message + ' — ' + result.repoName, true);
            await this.loadSavedConnections();
        } catch (e) {
            this._setStatus('Verify failed: ' + (e?.body?.message || e?.message || String(e)), false);
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Reconnect — fields pre-fill karke OAuth dobara chalao
    // ═══════════════════════════════════════════════════════════
    async reconnectConnection(event) {
        const name  = event.currentTarget.dataset.name;
        const owner = event.currentTarget.dataset.owner;
        const repo  = event.currentTarget.dataset.repo;
        this.connectionName = name;
        this.repoOwner      = owner;
        this.repoName       = repo;
        await this.initiateOAuth();
    }

    // ═══════════════════════════════════════════════════════════
    // Delete connection
    // ═══════════════════════════════════════════════════════════
    async deleteConnection(event) {
        const connId = event.currentTarget.dataset.id;
        const conn   = this.savedConnections.find(c => c.Id === connId);
        if (!window.confirm(
            `Delete connection "${conn ? conn.Name : ''}"?\n\nThis will remove the stored token.`
        )) return;
        try {
            await deleteConnectionApex({ connectionId: connId });
            this._setStatus('Connection deleted successfully.', true);
            await this.loadSavedConnections();
        } catch (e) {
            this._setStatus('Delete failed: ' + (e?.body?.message || e?.message || String(e)), false);
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Load saved connections
    // ═══════════════════════════════════════════════════════════
    async loadSavedConnections() {
        this.isLoadingConnections = true;
        try {
            const raw = await getSavedConnections();
            this.savedConnections = raw.map(conn => ({
                ...conn,
                repoFullName          : conn.Repo_Owner__c + '/' + conn.Repo_Name__c,
                statusBadgeClass      : conn.Status__c === 'Connected'
                    ? 'gh-badge-connected'
                    : 'gh-badge-disconnected',
                lastModifiedFormatted : new Date(conn.LastModifiedDate).toLocaleDateString()
            }));
        } catch (e) {
            this._setStatus('Could not load connections: ' + (e?.body?.message || e?.message || String(e)), false);
        } finally {
            this.isLoadingConnections = false;
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Helpers
    // ═══════════════════════════════════════════════════════════
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