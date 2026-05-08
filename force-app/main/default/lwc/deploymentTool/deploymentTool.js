import { LightningElement, track } from 'lwc';
import { loadScript }             from 'lightning/platformResourceLoader';
import JSZIP                      from '@salesforce/resourceUrl/JSZip';

import getComponents             from '@salesforce/apex/DeploymentToolCtrl.getComponents';
import getTargetComponents       from '@salesforce/apex/DeploymentToolCtrl.getTargetComponents';
import buildDestructiveXml       from '@salesforce/apex/DeploymentToolCtrl.buildDestructiveXml';
import getComponentDependencies  from '@salesforce/apex/DeploymentToolCtrl.getComponentDependencies';
import startRetrieve             from '@salesforce/apex/DeploymentToolCtrl.startRetrieve';
import checkRetrieveStatus       from '@salesforce/apex/DeploymentToolCtrl.checkRetrieveStatus';
import getMainBranchSha          from '@salesforce/apex/DeploymentToolCtrl.getMainBranchSha';
import createFeatureBranch       from '@salesforce/apex/DeploymentToolCtrl.createFeatureBranch';
import pushMultipleFilesToGitHub  from '@salesforce/apex/DeploymentToolCtrl.pushMultipleFilesToGitHub';
import createPullRequest         from '@salesforce/apex/DeploymentToolCtrl.createPullRequest';
import mergePullRequest          from '@salesforce/apex/DeploymentToolCtrl.mergePullRequest';
import getPreviousCommits        from '@salesforce/apex/DeploymentToolCtrl.getPreviousCommits';
import saveDeploymentLog         from '@salesforce/apex/DeploymentToolCtrl.saveDeploymentLog';
import syncDeploymentStatus      from '@salesforce/apex/DeploymentToolCtrl.syncDeploymentStatus';

// Environments tab — separate Apex controller
import getAuthorizationUrl      from '@salesforce/apex/EnvironmentManagerCtrl.getAuthorizationUrl';
import exchangeCodeAndSave      from '@salesforce/apex/EnvironmentManagerCtrl.exchangeCodeAndSave';
import getSavedEnvironments     from '@salesforce/apex/EnvironmentManagerCtrl.getSavedEnvironments';
import deleteEnvironmentApex    from '@salesforce/apex/EnvironmentManagerCtrl.deleteEnvironment';

const RETRIEVE_BATCH_SIZE    = 10;
const MAX_POLL_ATTEMPTS      = 80;
const POLL_INTERVAL_MS       = 5000;
const WORKFLOW_POLL_INTERVAL = 30000;
const WORKFLOW_MAX_ATTEMPTS  = 20;
const NAME_DISPLAY_MAX       = 14;

const POPUP_WIDTH  = 600;
const POPUP_HEIGHT = 700;

export default class DeploymentTool extends LightningElement {

    // ── Tab ────────────────────────────────────────────────
    @track activeTab = 'findChanges';

    // ── Deploy state ───────────────────────────────────────
    @track selectedType       = '';
    @track components         = [];
    @track selectedComponents = [];
    @track isLoading          = false;
    @track statusMessage      = '';
    @track statusClass        = 'slds-text-color_success';
    @track hasComponents      = false;
    @track progressLabel      = '';
    @track progressValue      = 0;
    @track showProgress       = false;

    // ── Filter state (Deploy tab) ──────────────────────────
    @track filterName          = '';
    @track filterLabel         = '';
    @track filterCreatedBy     = '';
    @track filterModifiedBy    = '';
    @track filterModifiedAfter = '';
    @track filterCreatedAfter  = '';

    // ── Delete state ───────────────────────────────────────
    @track selectedDeleteType   = '';
    @track targetComponents     = [];
    @track deleteComponents     = [];
    @track isDeleteLoading      = false;
    @track filterDeleteName     = '';

    // ── Prev Committed panel ───────────────────────────────
    @track showPrevCommitPanel  = false;
    @track isPrevCommitLoading  = false;
    @track prevCommitError      = '';
    @track prevCommits          = [];

    // ── Environments tab state ─────────────────────────────
    @track newEnvName             = '';
    @track newOrgType             = 'production';
    @track isConnecting           = false;
    @track connectingMessage      = '';
    @track connectStatusMessage   = '';
    @track connectStatusClass     = 'slds-text-color_success';
    @track savedEnvironments      = [];
    @track isLoadingEnvironments  = false;

    // Internal OAuth popup tracking (not tracked — no UI binding needed)
    _oauthPopup      = null;
    _pendingState    = null;
    _pendingOrgType  = null;
    _pendingEnvName  = null;
    _messageListener = null;

    jsZipLoaded = false;

    // ══════════════════════════════════════════════════════
    // LIFECYCLE
    // ══════════════════════════════════════════════════════
    connectedCallback() {
        loadScript(this, JSZIP)
            .then(() => { this.jsZipLoaded = true; })
            .catch(err => console.error('JSZip load failed:', err));

        this.loadSavedEnvironments();
    }

    disconnectedCallback() {
        this._removeOAuthMessageListener();
    }

    // ══════════════════════════════════════════════════════
    // LAYOUT & TAB CSS GETTERS
    // ══════════════════════════════════════════════════════
    get mainLayoutClass() {
        return this.showPrevCommitPanel
            ? 'slds-grid slds-wrap slds-m-around_medium'
            : 'slds-m-around_medium';
    }
    get mainContentClass() {
        return this.showPrevCommitPanel ? 'slds-col slds-has-flexi-truncate' : '';
    }
    get findChangesTabClass() {
        return this.activeTab === 'findChanges'
            ? 'slds-tabs_default__item slds-is-active'
            : 'slds-tabs_default__item';
    }
    get selectedChangesTabClass() {
        return this.activeTab === 'selectedChanges'
            ? 'slds-tabs_default__item slds-is-active'
            : 'slds-tabs_default__item';
    }
    get deleteTabClass() {
        return this.activeTab === 'deleteTab'
            ? 'slds-tabs_default__item slds-is-active'
            : 'slds-tabs_default__item';
    }
    get environmentsTabClass() {
        return this.activeTab === 'environments'
            ? 'slds-tabs_default__item slds-is-active'
            : 'slds-tabs_default__item';
    }
    get findChangesPanelClass() {
        return this.activeTab === 'findChanges'
            ? 'slds-tabs_default__content slds-show'
            : 'slds-tabs_default__content slds-hide';
    }
    get selectedChangesPanelClass() {
        return this.activeTab === 'selectedChanges'
            ? 'slds-tabs_default__content slds-show'
            : 'slds-tabs_default__content slds-hide';
    }
    get deleteTabPanelClass() {
        return this.activeTab === 'deleteTab'
            ? 'slds-tabs_default__content slds-show'
            : 'slds-tabs_default__content slds-hide';
    }
    get environmentsPanelClass() {
        return this.activeTab === 'environments'
            ? 'slds-tabs_default__content slds-show'
            : 'slds-tabs_default__content slds-hide';
    }

    // ══════════════════════════════════════════════════════
    // FILTER GETTERS — Deploy tab
    // ══════════════════════════════════════════════════════
    get filteredComponents() {
        let list = this.components;
        if (this.filterName && this.filterName.trim()) {
            const q = this.filterName.trim().toLowerCase();
            list = list.filter(c => c.name && c.name.toLowerCase().includes(q));
        }
        if (this.filterLabel && this.filterLabel.trim()) {
            const q = this.filterLabel.trim().toLowerCase();
            list = list.filter(c => c.label && c.label.toLowerCase().includes(q));
        }
        if (this.filterCreatedBy && this.filterCreatedBy.trim()) {
            const q = this.filterCreatedBy.trim().toLowerCase();
            list = list.filter(c => c.createdBy && c.createdBy.toLowerCase().includes(q));
        }
        if (this.filterModifiedBy && this.filterModifiedBy.trim()) {
            const q = this.filterModifiedBy.trim().toLowerCase();
            list = list.filter(c => c.lastModifiedBy && c.lastModifiedBy.toLowerCase().includes(q));
        }
        if (this.filterModifiedAfter && this.filterModifiedAfter.trim()) {
            const cutoff = this.filterModifiedAfter.trim();
            list = list.filter(c => c.lastModifiedDate && c.lastModifiedDate >= cutoff);
        }
        if (this.filterCreatedAfter && this.filterCreatedAfter.trim()) {
            const cutoff = this.filterCreatedAfter.trim();
            list = list.filter(c => c.createdDate && c.createdDate >= cutoff);
        }
        return list;
    }

    get hasActiveFilters() {
        return (this.filterName          && this.filterName.trim())          ||
               (this.filterLabel         && this.filterLabel.trim())         ||
               (this.filterCreatedBy     && this.filterCreatedBy.trim())     ||
               (this.filterModifiedBy    && this.filterModifiedBy.trim())    ||
               (this.filterModifiedAfter && this.filterModifiedAfter.trim()) ||
               (this.filterCreatedAfter  && this.filterCreatedAfter.trim());
    }

    get noFilteredResults() {
        return this.hasComponents && this.filteredComponents.length === 0;
    }

    get filterSummaryText() {
        if (!this.hasComponents) return 'Fetch components to see results';
        return `Showing ${this.filteredComponents.length} of ${this.components.length} components`;
    }

    get filteredTargetComponents() {
        if (!this.filterDeleteName || !this.filterDeleteName.trim()) return this.targetComponents;
        const q = this.filterDeleteName.trim().toLowerCase();
        return this.targetComponents.filter(c => c.name && c.name.toLowerCase().includes(q));
    }

    get hasSelectedComponents()    { return this.selectedComponents.length > 0; }
    get noItemsCheckedInSelected() { return !this.selectedComponents.some(c => c.markedForRemoval); }
    get hasPrevCommits()           { return this.prevCommits.length > 0; }
    get hasTargetComponents()      { return this.targetComponents.length > 0; }
    get hasDeleteComponents()      { return this.deleteComponents.length > 0; }
    get hasSavedEnvironments()     { return this.savedEnvironments.length > 0; }

    // ── Metadata Options ───────────────────────────────────
    metadataOptions = [
        { label: 'Apex Class',           value: 'ApexClass'               },
        { label: 'Apex Trigger',         value: 'ApexTrigger'             },
        { label: 'LWC',                  value: 'LightningComponentBundle' },
        { label: 'Aura Component',       value: 'AuraDefinitionBundle'    },
        { label: 'Flow',                 value: 'FlowDefinition'          },
        { label: 'Custom Object',        value: 'CustomObject'            },
        { label: 'Validation Rule',      value: 'ValidationRule'          },
        { label: 'Custom Field',         value: 'CustomField'             },
        { label: 'Permission Set',       value: 'PermissionSet'           },
        { label: 'Custom Label',         value: 'CustomLabel'             },
        { label: 'Static Resource',      value: 'StaticResource'          },
        { label: 'Visualforce Page',     value: 'ApexPage'                },
        { label: 'Email Template',       value: 'EmailTemplate'           },
        { label: 'Custom Metadata Type', value: 'CustomMetadataType'      },
        { label: 'Global Value Set',     value: 'GlobalValueSet'          },
        { label: 'Flexi Page',           value: 'FlexiPage'               }
    ];

    // ── Org Type Options (Environments tab) ───────────────
    get orgTypeOptions() {
        return [
            { label: 'Production', value: 'production' },
            { label: 'Sandbox',    value: 'sandbox'    }
        ];
    }

    // ══════════════════════════════════════════════════════
    // FILTER HANDLERS
    // ══════════════════════════════════════════════════════
    handleFilterChange(event) {
        const filterType = event.target.dataset.filter;
        const value      = event.detail.value;
        if (filterType === 'name')          this.filterName          = value;
        if (filterType === 'label')         this.filterLabel         = value;
        if (filterType === 'createdBy')     this.filterCreatedBy     = value;
        if (filterType === 'modifiedBy')    this.filterModifiedBy    = value;
        if (filterType === 'modifiedAfter') this.filterModifiedAfter = value;
        if (filterType === 'createdAfter')  this.filterCreatedAfter  = value;
    }

    clearFilters() {
        this.filterName          = '';
        this.filterLabel         = '';
        this.filterCreatedBy     = '';
        this.filterModifiedBy    = '';
        this.filterModifiedAfter = '';
        this.filterCreatedAfter  = '';
    }

    handleDeleteFilterChange(event) {
        this.filterDeleteName = event.detail.value;
    }

    // ══════════════════════════════════════════════════════
    // PREV COMMITTED PANEL
    // ══════════════════════════════════════════════════════
    async togglePrevCommitPanel() {
        this.showPrevCommitPanel = !this.showPrevCommitPanel;
        if (this.showPrevCommitPanel && this.prevCommits.length === 0) {
            await this.loadPreviousCommits();
        }
    }

    async loadPreviousCommits() {
        this.isPrevCommitLoading = true;
        this.prevCommitError     = '';
        try {
            const raw = await getPreviousCommits();
            this.prevCommits = raw.map(pr => {
                const groupedFiles = this.groupPrFiles(pr.files || []);
                return {
                    number    : pr.number,
                    title     : pr.title,
                    mergedAt  : pr.mergedAt,
                    files     : groupedFiles,
                    fileCount : groupedFiles.length,
                    expanded  : false,
                    expandIcon: 'utility:chevronright'
                };
            });
        } catch (e) {
            this.prevCommitError = this.getError(e);
        } finally {
            this.isPrevCommitLoading = false;
        }
    }

    groupPrFiles(files) {
        const seen = new Map();
        for (const file of files) {
            const key = file.name;
            if (!seen.has(key)) {
                seen.set(key, { path: file.path, name: file.name, metadataType: file.metadataType, fileNames: [this.getFileName(file.path)] });
            } else {
                seen.get(key).fileNames.push(this.getFileName(file.path));
            }
        }
        return Array.from(seen.values()).map(f => ({
            ...f,
            hasMultiple : f.fileNames.length > 1,
            fileCount   : f.fileNames.length,
            fileLabel   : f.fileNames.join(' + ')
        }));
    }

    getFileName(filePath) {
        if (!filePath) return '';
        const parts = filePath.split('/');
        return parts[parts.length - 1];
    }

    togglePrExpand(event) {
        let target = event.target;
        while (target && !target.dataset.pr) target = target.parentElement;
        if (!target) return;
        const prNum = parseInt(target.dataset.pr, 10);
        this.prevCommits = this.prevCommits.map(pr => {
            if (pr.number !== prNum) return pr;
            const expanded = !pr.expanded;
            return { ...pr, expanded, expandIcon: expanded ? 'utility:chevrondown' : 'utility:chevronright' };
        });
    }

    // ══════════════════════════════════════════════════════
    // TAB SWITCHING
    // ══════════════════════════════════════════════════════
    handleTabSwitch(event) { event.preventDefault(); this.activeTab = event.currentTarget.dataset.tab; }
    goToSelectedTab(event) { event.preventDefault(); this.activeTab = 'selectedChanges'; }
    goToFindTab(event)     { event.preventDefault(); this.activeTab = 'findChanges'; }

    // ══════════════════════════════════════════════════════
    // TYPE CHANGE
    // ══════════════════════════════════════════════════════
    handleTypeChange(event) {
        this.selectedType  = event.detail.value;
        this.components    = [];
        this.hasComponents = false;
        this.statusMessage = '';
        this.showProgress  = false;
        this.clearFilters();
    }

    handleDeleteTypeChange(event) {
        this.selectedDeleteType = event.detail.value;
        this.targetComponents   = [];
        this.deleteComponents   = [];
        this.filterDeleteName   = '';
    }

    // ══════════════════════════════════════════════════════
    // FETCH COMPONENTS (Source Org)
    // ══════════════════════════════════════════════════════
    async fetchComponents() {
        if (!this.selectedType) { this.setStatus('Please select a metadata type.', false); return; }
        this.isLoading     = true;
        this.statusMessage = '';
        this.showProgress  = false;
        try {
            const raw         = await getComponents({ metadataType: this.selectedType });
            const selectedIds = new Set(this.selectedComponents.map(c => c.id));
            this.components = raw.map(c => ({
                ...c,
                checked              : selectedIds.has(c.id),
                createdByDisplay     : this._truncate(c.createdBy),
                lastModifiedByDisplay: this._truncate(c.lastModifiedBy)
            }));
            this.hasComponents = this.components.length > 0;
            if (!this.hasComponents) this.setStatus('No components found.', false);
        } catch (e) {
            this.setStatus('Fetch Error: ' + this.getError(e), false);
        } finally {
            this.isLoading = false;
        }
    }

    // ══════════════════════════════════════════════════════
    // FETCH TARGET COMPONENTS (Delete tab)
    // ══════════════════════════════════════════════════════
    async fetchTargetComponents() {
        if (!this.selectedDeleteType) { this.setStatus('Please select a metadata type.', false); return; }
        this.isDeleteLoading  = true;
        this.targetComponents = [];
        this.deleteComponents = [];
        this.filterDeleteName = '';
        try {
            const raw = await getTargetComponents({ metadataType: this.selectedDeleteType });
            this.targetComponents = raw.map(c => ({ ...c, checkedForDelete: false }));
            if (this.targetComponents.length === 0)
                this.setStatus('No components of this type were found in the Target Org.', false);
        } catch (e) {
            this.setStatus('Target Org fetch error: ' + this.getError(e), false);
        } finally {
            this.isDeleteLoading = false;
        }
    }

    // ══════════════════════════════════════════════════════
    // SELECTION — Deploy tab
    // ══════════════════════════════════════════════════════
    handleSelection(event) {
        const id      = event.target.dataset.id;
        const name    = event.target.dataset.name;
        const checked = event.target.checked;
        this.components = this.components.map(c => c.id === id ? { ...c, checked } : c);
        if (checked) {
            if (!this.selectedComponents.some(c => c.id === id)) {
                const src = this.components.find(c => c.id === id) || {};
                this.selectedComponents = [
                    ...this.selectedComponents,
                    {
                        id, name,
                        metadataType         : this.selectedType,
                        markedForRemoval     : false,
                        rowNum               : 0,
                        label                : src.label || '',
                        createdBy            : src.createdBy || '',
                        lastModifiedBy       : src.lastModifiedBy || '',
                        lastModifiedByDisplay: src.lastModifiedByDisplay || '',
                        lastModifiedDate     : src.lastModifiedDate || '',
                        createdDate          : src.createdDate || ''
                    }
                ];
                this._reNumberRows();
            }
        } else {
            this.selectedComponents = this.selectedComponents.filter(c => c.id !== id);
            this._reNumberRows();
        }
    }

    selectAll() {
        const filtered = this.filteredComponents;
        this.components = this.components.map(c => {
            const inFiltered = filtered.some(f => f.id === c.id);
            return inFiltered ? { ...c, checked: true } : c;
        });
        const newOnes = filtered
            .filter(c => !this.selectedComponents.some(s => s.id === c.id))
            .map(c => ({
                id: c.id, name: c.name,
                metadataType         : this.selectedType,
                markedForRemoval     : false,
                rowNum               : 0,
                label                : c.label || '',
                createdBy            : c.createdBy || '',
                lastModifiedBy       : c.lastModifiedBy || '',
                lastModifiedByDisplay: c.lastModifiedByDisplay || '',
                lastModifiedDate     : c.lastModifiedDate || '',
                createdDate          : c.createdDate || ''
            }));
        if (newOnes.length > 0) {
            this.selectedComponents = [...this.selectedComponents, ...newOnes];
            this._reNumberRows();
        }
    }

    deselectAll() {
        const filteredIds = new Set(this.filteredComponents.map(c => c.id));
        this.selectedComponents = this.selectedComponents.filter(c => !filteredIds.has(c.id));
        this._reNumberRows();
        this.components = this.components.map(c =>
            filteredIds.has(c.id) ? { ...c, checked: false } : c
        );
    }

    handleRemovalCheck(event) {
        const id      = event.target.dataset.id;
        const checked = event.target.checked;
        this.selectedComponents = this.selectedComponents.map(c =>
            c.id === id ? { ...c, markedForRemoval: checked } : c
        );
    }

    removeCheckedFromSelected() {
        const removedIds = this.selectedComponents.filter(c => c.markedForRemoval).map(c => c.id);
        this.selectedComponents = this.selectedComponents.filter(c => !c.markedForRemoval);
        this._reNumberRows();
        this.components = this.components.map(c =>
            removedIds.includes(c.id) ? { ...c, checked: false } : c
        );
        if (this.selectedComponents.length === 0) {
            this.statusMessage = ''; this.showProgress = false;
            this.progressValue = 0;  this.progressLabel = '';
        }
    }

    _reNumberRows() {
        this.selectedComponents = this.selectedComponents.map((c, i) => ({ ...c, rowNum: i + 1 }));
    }

    // ══════════════════════════════════════════════════════
    // SELECTION — Delete tab
    // ══════════════════════════════════════════════════════
    handleDeleteSelection(event) {
        const id      = event.target.dataset.id;
        const name    = event.target.dataset.name;
        const checked = event.target.checked;
        this.targetComponents = this.targetComponents.map(c =>
            c.id === id ? { ...c, checkedForDelete: checked } : c
        );
        if (checked) {
            if (!this.deleteComponents.some(c => c.id === id)) {
                this.deleteComponents = [...this.deleteComponents, { id, name, metadataType: this.selectedDeleteType }];
            }
        } else {
            this.deleteComponents = this.deleteComponents.filter(c => c.id !== id);
        }
    }

    selectAllDelete() {
        const filtered = this.filteredTargetComponents;
        this.targetComponents = this.targetComponents.map(c => {
            const inFiltered = filtered.some(f => f.id === c.id);
            return inFiltered ? { ...c, checkedForDelete: true } : c;
        });
        const newOnes = filtered
            .filter(c => !this.deleteComponents.some(d => d.id === c.id))
            .map(c => ({ id: c.id, name: c.name, metadataType: this.selectedDeleteType }));
        if (newOnes.length > 0) this.deleteComponents = [...this.deleteComponents, ...newOnes];
    }

    deselectAllDelete() {
        this.targetComponents = this.targetComponents.map(c => ({ ...c, checkedForDelete: false }));
        this.deleteComponents = [];
    }

    // ══════════════════════════════════════════════════════
    // EXECUTE DELETE
    // ══════════════════════════════════════════════════════
    async executeDelete() {
        if (!this.deleteComponents.length) { this.setStatus('No components selected for deletion.', false); return; }
        const confirmMsg = `⚠️ WARNING!\n\nThese ${this.deleteComponents.length} component(s) will be permanently deleted from the Target Org:\n\n` +
            this.deleteComponents.map(c => `• ${c.name} (${c.metadataType})`).join('\n') + '\n\nAre you sure?';
        if (!window.confirm(confirmMsg)) return;
        this.isLoading = true; this.showProgress = true; this.statusMessage = '';
        try {
            this.updateProgress('Step 1/4 — Building destructiveChanges.xml...', 10);
            const destructiveXml = await buildDestructiveXml({
                componentsToDelete: this.deleteComponents.map(c => ({ name: c.name, metadataType: c.metadataType }))
            });
            const blankPackageXml =
                '<?xml version="1.0" encoding="UTF-8"?>\n' +
                '<Package xmlns="http://soap.sforce.com/2006/04/metadata">\n' +
                '  <version>64.0</version>\n</Package>';
            this.updateProgress('Step 2/4 — Creating GitHub branch...', 30);
            const sha        = await getMainBranchSha();
            const branchName = `delete/destructive-${Date.now()}`;
            await createFeatureBranch({ branchName, sha });
            this.updateProgress('Step 3/4 — Pushing files...', 55);
            await pushMultipleFilesToGitHub({
                branchName,
                commitMessage : `Delete: ${this.deleteComponents.length} components from Target Org`,
                files         : [
                    { filePath: 'package.xml',               base64Content: btoa(unescape(encodeURIComponent(blankPackageXml))) },
                    { filePath: 'destructiveChangesPost.xml', base64Content: btoa(unescape(encodeURIComponent(destructiveXml)))  }
                ]
            });
            this.updateProgress('Step 4/4 — Creating and merging PR...', 75);
            const title    = `Delete: ${this.deleteComponents.map(c => c.name).join(', ').substring(0, 60)}`;
            const prNumber = await createPullRequest({ branchName, title });
            await mergePullRequest({ prNumber });
            const logId = await saveDeploymentLog({
                prNumber, prTitle: title, branchName,
                components: this.deleteComponents.map(c => ({ name: c.name, metadataType: c.metadataType, filePath: '', operation: 'Delete' }))
            });
            this.updateProgress('Waiting for GitHub Actions to complete...', 85);
            const finalStatus = await this.pollWorkflowStatus(logId, branchName);
            if (finalStatus === 'Deployed') {
                this.updateProgress(`Delete successful! PR #${prNumber}`, 100);
                this.setStatus(`${this.deleteComponents.length} components deleted! PR #${prNumber}`, true);
                this.deleteComponents = []; this.targetComponents = []; this.selectedDeleteType = '';
            } else {
                this.setStatus(`PR #${prNumber} merged but GitHub Actions failed.`, false);
            }
            if (this.showPrevCommitPanel) { this.prevCommits = []; await this.loadPreviousCommits(); }
        } catch (e) {
            this.setStatus('Delete Error: ' + this.getError(e), false);
            this.showProgress = false;
        } finally {
            this.isLoading = false;
        }
    }

    // ══════════════════════════════════════════════════════
    // CLEAN OBJECT XML
    // ══════════════════════════════════════════════════════
    cleanObjectXml(xmlStr) {
        const parts = xmlStr.split('<actionOverrides>');
        const result = [parts[0]];
        for (let i = 1; i < parts.length; i++) {
            const closing = parts[i].indexOf('</actionOverrides>');
            if (closing === -1) { result.push('<actionOverrides>' + parts[i]); continue; }
            const block = parts[i].substring(0, closing);
            const rest  = parts[i].substring(closing + '</actionOverrides>'.length);
            if (block.includes('<type>Flexipage</type>')) { result.push(rest); }
            else { result.push('<actionOverrides>' + block + '</actionOverrides>' + rest); }
        }
        return result.join('');
    }

    // ══════════════════════════════════════════════════════
    // MAIN DEPLOY FLOW
    // ══════════════════════════════════════════════════════
    async deploySelected() {
        if (!this.selectedComponents.length) { this.setStatus('Please select at least one component.', false); return; }
        if (!this.jsZipLoaded) { this.setStatus('JSZip still loading, please wait...', false); return; }
        this.isLoading = true; this.showProgress = true;
        try {
            this.updateProgress('Step 0/5 — Checking Dependencies...', 2);
            const compIds = this.selectedComponents.map(c => c.id).filter(id => id && !id.startsWith('dep_'));
            if (compIds.length > 0) {
                const deps    = await getComponentDependencies({ componentIds: compIds });
                const newDeps = deps.filter(d => !this.selectedComponents.some(sc => sc.name === d.name && sc.metadataType === d.metadataType));
                if (newDeps.length > 0) {
                    const sampleName = `${newDeps[0].metadataType}: ${newDeps[0].name}`;
                    const confirmMsg = `Missing Dependencies Found!\n\n${newDeps.length} components needed (e.g., ${sampleName}).\n\nAdd them automatically?`;
                    if (window.confirm(confirmMsg)) {
                        const formattedDeps = newDeps.map((d, index) => ({
                            id: 'dep_' + Date.now() + index, name: d.name, metadataType: d.metadataType,
                            markedForRemoval: false, rowNum: 0, label: '', createdBy: '', lastModifiedBy: '',
                            lastModifiedByDisplay: '', lastModifiedDate: '', createdDate: ''
                        }));
                        this.selectedComponents = [...this.selectedComponents, ...formattedDeps];
                        this._reNumberRows();
                    }
                }
            }
            this.updateProgress('Step 1/5 — Retrieving from Source Org...', 5);
            const rawFiles = await this.batchedRetrieveByType();
            const allFiles = rawFiles.map(f => {
                if (f.path.includes('/objects/') && f.path.endsWith('.object')) {
                    try {
                        const xmlStr  = decodeURIComponent(escape(atob(f.content)));
                        const cleaned = this.cleanObjectXml(xmlStr);
                        return { ...f, content: btoa(unescape(encodeURIComponent(cleaned))) };
                    } catch (e) { return f; }
                }
                return f;
            });
            this.updateProgress('Step 2/5 — Creating GitHub feature branch...', 35);
            const branchName = await this.setupGitBranch();
            this.updateProgress('Step 3/5 — Pushing all files to GitHub...', 45);
            const packageXml    = this.buildOrderedPackageXml();
            const allFilesToPush = [
                { path: 'package.xml', content: btoa(unescape(encodeURIComponent(packageXml))) },
                ...allFiles.filter(f => f.path !== 'package.xml')
            ];
            await this.pushAllFilesWithRetry(allFilesToPush, branchName);
            this.updateProgress('Step 4/5 — Creating PR and merging...', 80);
            const uniqueTypes = [...new Set(this.selectedComponents.map(c => c.metadataType))].join(', ');
            const title       = `Deploy: ${uniqueTypes} (${this.selectedComponents.length} components)`;
            const prNumber    = await createPullRequest({ branchName, title });
            await mergePullRequest({ prNumber });
            const componentData = this.selectedComponents.map(c => {
                const matched  = allFiles.find(f => f.path.toLowerCase().includes(c.name.toLowerCase()) && !f.path.endsWith('-meta.xml'));
                const fallback = allFiles.find(f => f.path.toLowerCase().includes(c.name.toLowerCase()));
                return { name: c.name, metadataType: c.metadataType, filePath: matched ? matched.path : (fallback ? fallback.path : ''), operation: 'Deploy' };
            });
            const logId = await saveDeploymentLog({ prNumber, prTitle: title, branchName, components: componentData });
            this.updateProgress('Step 5/5 — Waiting for GitHub Actions...', 85);
            const finalStatus = await this.pollWorkflowStatus(logId, branchName);
            if (finalStatus === 'Deployed') {
                this.updateProgress(`Done! PR #${prNumber} deployed successfully.`, 100);
                this.setStatus(`PR #${prNumber} merged! ${this.selectedComponents.length} components deployed.`, true);
            } else {
                this.setStatus(`PR #${prNumber} merged but GitHub Actions failed. Check logs.`, false);
            }
            if (this.showPrevCommitPanel) { this.prevCommits = []; await this.loadPreviousCommits(); }
        } catch (e) {
            this.setStatus('Error: ' + this.getError(e), false);
            this.showProgress = false;
        } finally {
            this.isLoading = false;
        }
    }

    buildOrderedPackageXml() {
        const DEPLOY_ORDER = {
            'CustomObject': 1, 'CustomField': 2, 'ValidationRule': 3, 'GlobalValueSet': 4,
            'CustomLabel': 5, 'StaticResource': 6, 'ApexClass': 7, 'ApexTrigger': 8,
            'ApexPage': 9, 'LightningComponentBundle': 10, 'AuraDefinitionBundle': 11,
            'FlowDefinition': 12, 'PermissionSet': 13, 'EmailTemplate': 14, 'FlexiPage': 15
        };
        const byType = {};
        for (const comp of this.selectedComponents) {
            const type = comp.metadataType, name = comp.name;
            if ((type === 'CustomObject' || type === 'CustomMetadataType') && !name.endsWith('__c') && !name.endsWith('__mdt')) continue;
            if (!byType[type]) byType[type] = [];
            if (!byType[type].includes(name)) byType[type].push(name);
        }
        const sortedTypes = Object.keys(byType).sort((a, b) => (DEPLOY_ORDER[a] || 99) - (DEPLOY_ORDER[b] || 99));
        let typesXml = '';
        for (const type of sortedTypes) {
            let pkgType = type;
            if (pkgType === 'FlowDefinition')     pkgType = 'Flow';
            if (pkgType === 'CustomMetadataType') pkgType = 'CustomObject';
            const membersXml = byType[type].map(name => `    <members>${name}</members>`).join('\n');
            typesXml += `  <types>\n${membersXml}\n    <name>${pkgType}</name>\n  </types>\n`;
        }
        return `<?xml version="1.0" encoding="UTF-8"?>\n<Package xmlns="http://soap.sforce.com/2006/04/metadata">\n${typesXml}  <version>64.0</version>\n</Package>`;
    }

    async pollWorkflowStatus(logId, branchName) {
        for (let i = 0; i < WORKFLOW_MAX_ATTEMPTS; i++) {
            await this.sleep(WORKFLOW_POLL_INTERVAL);
            const elapsedMin = Math.floor(((i + 1) * 30) / 60);
            const elapsedSec = ((i + 1) * 30) % 60;
            const elapsed    = elapsedMin > 0 ? `${elapsedMin}m ${elapsedSec}s` : `${elapsedSec}s`;
            this.updateProgress(`GitHub Actions running... (${elapsed} elapsed)`, 85 + Math.min(i, 12));
            const status = await syncDeploymentStatus({ logId, branchName });
            if (status === 'Deployed' || status === 'Failed') return status;
        }
        await syncDeploymentStatus({ logId, branchName });
        return 'Failed';
    }

    async batchedRetrieveByType() {
        const byType = {};
        for (const comp of this.selectedComponents) {
            if (!byType[comp.metadataType]) byType[comp.metadataType] = [];
            byType[comp.metadataType].push(comp.name);
        }
        const types = Object.keys(byType), allFiles = new Map();
        let totalDone = 0, succeeded = 0;
        const totalBatches = types.reduce((sum, t) => sum + Math.ceil(byType[t].length / RETRIEVE_BATCH_SIZE), 0);
        for (const metadataType of types) {
            const batches = this.chunkArray(byType[metadataType], RETRIEVE_BATCH_SIZE);
            for (let i = 0; i < batches.length; i++) {
                totalDone++;
                this.updateProgress(`Retrieving ${metadataType} — batch ${i + 1}/${batches.length}...`, 5 + Math.round((totalDone / totalBatches) * 25));
                try {
                    const zipBase64 = await this.retrieveZipForBatch(batches[i], metadataType);
                    const files     = await this.unzipFiles(zipBase64, metadataType);
                    for (const f of files) allFiles.set(f.path, f.content);
                    succeeded++;
                } catch (e) {
                    console.error(`${metadataType} batch ${i + 1} failed:`, e);
                    this.setStatus(`${metadataType} batch ${i + 1} failed — ${this.getError(e)}`, false);
                    await this.sleep(2000);
                }
            }
        }
        if (succeeded === 0) throw new Error('All retrieval batches failed. Please retry.');
        const result = [];
        for (const [path, content] of allFiles.entries()) result.push({ path, content });
        return result;
    }

    async retrieveZipForBatch(componentNames, metadataType) {
        const jobId = await startRetrieve({ componentNames, metadataType });
        for (let i = 0; i < MAX_POLL_ATTEMPTS; i++) {
            await this.sleep(POLL_INTERVAL_MS);
            const result = await checkRetrieveStatus({ jobId });
            if (result.status === 'Succeeded') return result.zip;
            if (result.status === 'Failed') throw new Error('Retrieve failed: ' + result.message);
        }
        throw new Error('Retrieve timed out after 2 minutes.');
    }

    async unzipFiles(base64Zip, metadataType) {
        const binary = atob(base64Zip);
        const bytes  = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        const zip = await JSZip.loadAsync(bytes);
        const files = [];
        const SKIP_FOLDERS = ['layouts', 'profiles'];
        for (const [filename, fileObj] of Object.entries(zip.files)) {
            if (!fileObj.dir) {
                let cleanPath = filename.replace(/^unpackaged\//, '');
                if (cleanPath.endsWith('.flexipage')) cleanPath = cleanPath + '-meta.xml';
                const shouldSkip = SKIP_FOLDERS.some(folder => cleanPath.includes(`/${folder}/`) || cleanPath.startsWith(`${folder}/`));
                if (shouldSkip) continue;
                if (cleanPath.endsWith('.object')) {
                    let xmlStr = await fileObj.async('string');
                    if (cleanPath.endsWith('__mdt.object') && !xmlStr.includes('<label>')) {
                        const rawName = cleanPath.split('/').pop().replace('__mdt.object', '');
                        const labelName = rawName.replace(/_/g, ' ');
                        const fieldsRegex = /<fields>[\s\S]*<\/fields>/g;
                        const fieldsMatch = xmlStr.match(fieldsRegex);
                        const fieldsContent = fieldsMatch ? fieldsMatch.join('\n') : '';
                        xmlStr = `<?xml version="1.0" encoding="UTF-8"?>\n<CustomObject xmlns="http://soap.sforce.com/2006/04/metadata">\n    <label>${labelName}</label>\n    <pluralLabel>${labelName}s</pluralLabel>\n    <visibility>Public</visibility>\n    ${fieldsContent}\n</CustomObject>`;
                    } else if (this.cleanObjectXml) {
                        xmlStr = this.cleanObjectXml(xmlStr);
                    }
                    files.push({ path: cleanPath, content: btoa(unescape(encodeURIComponent(xmlStr))) });
                } else {
                    files.push({ path: cleanPath, content: await fileObj.async('base64') });
                }
            }
        }
        return files;
    }

    async setupGitBranch() {
        const sha = await getMainBranchSha();
        const uniqueTypes = [...new Set(this.selectedComponents.map(c => c.metadataType))].join('_').substring(0, 40);
        const safeName    = this.selectedComponents[0].name.replace(/[^a-zA-Z0-9]/g, '_').substring(0, 20);
        const branchName  = `deploy/${uniqueTypes}-${safeName}-${Date.now()}`;
        await createFeatureBranch({ branchName, sha });
        return branchName;
    }

    async pushAllFilesWithRetry(files, branchName) {
        const uniqueTypes = [...new Set(this.selectedComponents.map(c => c.metadataType))].join(', ');
        const commitMsg   = `Deploy: ${uniqueTypes} — ${this.selectedComponents.length} components`;
        this.updateProgress(`Pushing all ${files.length} files to GitHub...`, 60);
        try {
            await pushMultipleFilesToGitHub({ branchName, commitMessage: commitMsg, files: files.map(f => ({ filePath: f.path, base64Content: f.content })) });
        } catch (error) {
            throw new Error('Bulk push failed: ' + this.getError(error));
        }
    }

    // ══════════════════════════════════════════════════════
    // ENVIRONMENTS TAB — OAuth flow
    // ══════════════════════════════════════════════════════
    handleEnvNameChange(event) {
        this.newEnvName = event.detail.value;
    }

    handleOrgTypeChange(event) {
        this.newOrgType = event.detail.value;
    }

    async initiateOAuth() {
        const envName = (this.newEnvName || '').trim();
        if (!envName) {
            this._setConnectStatus('Please enter an Environment Name before connecting.', false);
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
    orgType        : this.newOrgType,
    stateToken     : stateToken,
    environmentName: envName
});

            const left     = Math.round((screen.width  - POPUP_WIDTH)  / 2);
            const top      = Math.round((screen.height - POPUP_HEIGHT) / 2);
            const features = `width=${POPUP_WIDTH},height=${POPUP_HEIGHT},left=${left},top=${top},toolbar=no,menubar=no,scrollbars=yes,resizable=yes`;

            this._oauthPopup = window.open(authUrl, 'SalesforceOAuth', features);

            if (!this._oauthPopup || this._oauthPopup.closed) {
                throw new Error('Popup was blocked. Please allow popups for this site in your browser settings.');
            }

            this.connectingMessage = 'Waiting for you to log in...';
            this._attachOAuthMessageListener();

        } catch (e) {
            this.isConnecting = false;
            this._setConnectStatus('Error: ' + (e?.body?.message || e?.message || String(e)), false);
        }
    }

    _attachOAuthMessageListener() {
        this._removeOAuthMessageListener();
        this._messageListener = this._handleOAuthMessage.bind(this);
        window.addEventListener('message', this._messageListener);
    }

    _removeOAuthMessageListener() {
        if (this._messageListener) {
            window.removeEventListener('message', this._messageListener);
            this._messageListener = null;
        }
    }

  async _handleOAuthMessage(event) {
    // Accept any Salesforce domain — security is enforced by state token check below
    const origin = event.origin || '';
    const isSalesforce =
        origin.includes('.force.com')      ||
        origin.includes('.salesforce.com') ||
        origin.includes('.visualforce.com');

    if (!isSalesforce) return;

    const data = event.data;
    if (!data || data.type !== 'SF_OAUTH_CALLBACK') return;

    this._removeOAuthMessageListener();

    if (!data.success) {
        this.isConnecting = false;
        this._setConnectStatus(
            'Authentication failed: ' + (data.message || data.error),
            false
        );
        return;
    }

    if (data.state !== this._pendingState) {
        this.isConnecting = false;
        this._setConnectStatus(
            'Security check failed: state mismatch. Please try again.',
            false
        );
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
        this._setConnectStatus(result.message, true);
        this.newEnvName = '';
        this.newOrgType = 'production';
        await this.loadSavedEnvironments();
    } catch (e) {
        this.isConnecting = false;
        this._setConnectStatus(
            e?.body?.message || e?.message || String(e),
            false
        );
    } finally {
        this._pendingState   = null;
        this._pendingOrgType = null;
        this._pendingEnvName = null;
    }
}

    reconnectEnvironment(event) {
        const name    = event.currentTarget.dataset.name;
        const orgType = event.currentTarget.dataset.type;
        this.newEnvName  = name;
        this.newOrgType  = (orgType === 'Sandbox') ? 'sandbox' : 'production';
        this.initiateOAuth();
    }

    async deleteEnvironment(event) {
        const envId = event.currentTarget.dataset.id;
        const env   = this.savedEnvironments.find(e => e.Id === envId);
        if (!window.confirm(
            `Are you sure you want to delete the environment "${env ? env.Name : ''}"?\n\nThis will remove the stored credentials.`
        )) return;
        try {
            await deleteEnvironmentApex({ environmentId: envId });
            this._setConnectStatus('Environment deleted successfully.', true);
            await this.loadSavedEnvironments();
        } catch (e) {
            this._setConnectStatus('Delete failed: ' + (e?.body?.message || e?.message || String(e)), false);
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
                        : 'slds-badge'
            }));
        } catch (e) {
            this._setConnectStatus(
                'Could not load environments: ' + (e?.body?.message || e?.message || String(e)),
                false
            );
        } finally {
            this.isLoadingEnvironments = false;
        }
    }

    _setConnectStatus(message, isSuccess) {
        this.connectStatusMessage = message;
        this.connectStatusClass   = isSuccess ? 'slds-text-color_success' : 'slds-text-color_error';
    }

    _generateStateToken() {
        const arr = new Uint8Array(16);
        crypto.getRandomValues(arr);
        return Array.from(arr, b => b.toString(16).padStart(2, '0')).join('');
    }

    // ══════════════════════════════════════════════════════
    // UTILITIES
    // ══════════════════════════════════════════════════════
    _truncate(str) {
        if (!str) return '';
        return str.length > NAME_DISPLAY_MAX ? str.substring(0, NAME_DISPLAY_MAX) + '...' : str;
    }
    chunkArray(arr, size) {
        const chunks = [];
        for (let i = 0; i < arr.length; i += size) chunks.push(arr.slice(i, i + size));
        return chunks;
    }
    updateProgress(label, value) {
        this.progressLabel = label; this.progressValue = value;
        this.statusMessage = label;
        this.statusClass   = value === 100 ? 'slds-text-color_success' : 'slds-text-color_default';
    }
    setStatus(msg, isSuccess) {
        this.statusMessage = msg;
        this.statusClass   = isSuccess ? 'slds-text-color_success' : 'slds-text-color_error';
    }
    getError(e) { return e?.body?.message || e?.message || JSON.stringify(e); }
    sleep(ms)   { return new Promise(resolve => setTimeout(resolve, ms)); }
}