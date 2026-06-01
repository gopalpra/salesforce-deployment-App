import { LightningElement, track } from 'lwc';
import { CurrentPageReference }    from 'lightning/navigation';
import { loadScript }              from 'lightning/platformResourceLoader';
import { wire }                    from 'lwc';
import JSZIP                       from '@salesforce/resourceUrl/JSZip';

import getComponentsDynamic           from '@salesforce/apex/DeploymentToolCtrl.getComponentsDynamic';
import getComponentDependencies       from '@salesforce/apex/DeploymentToolCtrl.getComponentDependencies';
import startRetrieveDynamic           from '@salesforce/apex/DeploymentToolCtrl.startRetrieveDynamic';
import checkRetrieveStatusDynamic     from '@salesforce/apex/DeploymentToolCtrl.checkRetrieveStatusDynamic';
import getMainBranchSha               from '@salesforce/apex/DeploymentToolCtrl.getMainBranchSha';
import createFeatureBranch            from '@salesforce/apex/DeploymentToolCtrl.createFeatureBranch';
import pushMultipleFilesToGitHub      from '@salesforce/apex/DeploymentToolCtrl.pushMultipleFilesToGitHub';
import createPullRequest              from '@salesforce/apex/DeploymentToolCtrl.createPullRequest';
import mergePullRequest               from '@salesforce/apex/DeploymentToolCtrl.mergePullRequest';
import getPreviousCommits             from '@salesforce/apex/DeploymentToolCtrl.getPreviousCommits';
import saveDeploymentLog              from '@salesforce/apex/DeploymentToolCtrl.saveDeploymentLog';
import getOrgDetailsFromUserStory     from '@salesforce/apex/DeploymentToolCtrl.getOrgDetailsFromUserStory';
import refreshAccessToken             from '@salesforce/apex/DeploymentToolCtrl.refreshAccessToken';
import getUserStoryName               from '@salesforce/apex/DeploymentToolCtrl.getUserStoryName';
import saveCommitAndComponentRecords  from '@salesforce/apex/DeploymentToolCtrl.saveCommitAndComponentRecords';

import getExistingBranchForUserStory  from '@salesforce/apex/DeploymentToolCtrl.getExistingBranchForUserStory';
import deleteFeatureBranchAndClosePR  from '@salesforce/apex/DeploymentToolCtrl.deleteFeatureBranchAndClosePR';

const RETRIEVE_BATCH_SIZE  = 10;
const MAX_POLL_ATTEMPTS    = 80;
const POLL_INTERVAL_MS     = 5000;
const DEPLOY_POLL_INTERVAL = 5000;
const DEPLOY_MAX_ATTEMPTS  = 120;
const NAME_DISPLAY_MAX     = 14;
const SKIP_COMPONENTS = [
    'OAuthCallbackCtrl',
    'OAuthCallback'
];

export default class DeploymentTool extends LightningElement {

    // ── Tab ─────────────────────────────────────────────────
    @track activeTab = 'findChanges';

    // ── User Story / Dynamic Org state ──────────────────────
    @track userStoryId          = null;
    @track sourceOrgName        = '';
    @track targetOrgName        = '';
    @track sourceAccessToken    = null;
    @track sourceInstanceUrl    = null;
    @track targetAccessToken    = null;
    @track targetInstanceUrl    = null;
    @track orgLoadError         = '';
    @track isOrgLoading         = false;
    @track orgsReady            = false;

    // ── Deploy state ─────────────────────────────────────────
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

    // ── Filter state ─────────────────────────────────────────
    @track filterName          = '';
    @track filterLabel         = '';
    @track filterCreatedBy     = '';
    @track filterModifiedBy    = '';
    @track filterModifiedAfter = '';
    @track filterCreatedAfter  = '';

    // ── Pagination state ──────────────────────────────────────
    @track currentPage = 1;
    @track pageSize    = 25;

    // ── Prev Committed panel ──────────────────────────────────
    @track showPrevCommitPanel = false;
    @track isPrevCommitLoading = false;
    @track prevCommitError     = '';
    @track prevCommits         = [];

    // ── Commit Modal State ────────────────────────────────────
    @track showCommitModal      = false;
    @track createNewBranch      = false;
    @track existingBranchName   = null;
    @track isModalLoading       = false;

    jsZipLoaded = false;

    // ══════════════════════════════════════════════════════════
    // LIFECYCLE
    // ══════════════════════════════════════════════════════════
    connectedCallback() {
        loadScript(this, JSZIP)
            .then(() => { this.jsZipLoaded = true; })
            .catch(err => console.error('JSZip load failed:', err));
    }

    // ══════════════════════════════════════════════════════════
    // WIRE — Get userStoryId from URL
    // ══════════════════════════════════════════════════════════
    @wire(CurrentPageReference)
    async handlePageRef(pageRef) {
        const storyId = pageRef?.state?.c__userStoryId;
        if (storyId && storyId !== this.userStoryId) {
            this.userStoryId = storyId;
            this._resetAllState();
            await this.loadOrgsFromUserStory();
        }
    }

    // ══════════════════════════════════════════════════════════
    // FULL STATE RESET
    // ══════════════════════════════════════════════════════════
    _resetAllState() {
        this.selectedComponents = [];
        this.components         = [];
        this.hasComponents      = false;
        this.selectedType       = '';
        this.statusMessage      = '';
        this.statusClass        = 'slds-text-color_success';
        this.showProgress       = false;
        this.progressValue      = 0;
        this.progressLabel      = '';
        this.isLoading          = false;
        this.filterName          = '';
        this.filterLabel         = '';
        this.filterCreatedBy     = '';
        this.filterModifiedBy    = '';
        this.filterModifiedAfter = '';
        this.filterCreatedAfter  = '';
        this.prevCommits         = [];
        this.prevCommitError     = '';
        this.showPrevCommitPanel = false;
        this.isPrevCommitLoading = false;
        this.activeTab           = 'findChanges';
        this.orgsReady           = false;
        this.orgLoadError        = '';
        this.sourceOrgName       = '';
        this.targetOrgName       = '';
        this.sourceAccessToken   = null;
        this.sourceInstanceUrl   = null;
        this.targetAccessToken   = null;
        this.targetInstanceUrl   = null;
        // Modal reset
        this.showCommitModal     = false;
        this.createNewBranch     = false;
        this.existingBranchName  = null;
        this.isModalLoading      = false;
        // Pagination reset
        this.currentPage         = 1;
        this.pageSize            = 25;
    }

    // ══════════════════════════════════════════════════════════
    // Load orgs from User Story → refresh tokens
    // ══════════════════════════════════════════════════════════
    async loadOrgsFromUserStory() {
        this.isOrgLoading = true;
        this.orgLoadError = '';
        this.orgsReady    = false;
        try {
            const orgDetails = await getOrgDetailsFromUserStory({
                userStoryId: this.userStoryId
            });

            this.sourceOrgName = orgDetails.sourceOrgName || 'Source Org';
            this.targetOrgName = orgDetails.targetOrgName || 'Target Org';

            const sourceToken = await refreshAccessToken({
                refreshToken : orgDetails.sourceRefreshToken,
                orgType      : orgDetails.sourceOrgType,
                orgName      : orgDetails.sourceOrgName
            });
            this.sourceAccessToken = sourceToken.accessToken;
            this.sourceInstanceUrl = sourceToken.instanceUrl;

            const targetToken = await refreshAccessToken({
                refreshToken : orgDetails.targetRefreshToken,
                orgType      : orgDetails.targetOrgType,
                orgName      : orgDetails.targetOrgName
            });
            this.targetAccessToken = targetToken.accessToken;
            this.targetInstanceUrl = targetToken.instanceUrl;

            this.orgsReady = true;

        } catch(e) {
            this.orgLoadError = this.getError(e);
            this.orgsReady    = false;
        } finally {
            this.isOrgLoading = false;
        }
    }

    // ══════════════════════════════════════════════════════════
    // ORG BANNER GETTERS
    // ══════════════════════════════════════════════════════════
    get showOrgBanner() {
        return !!this.userStoryId;
    }

    get orgBannerMessage() {
        if (this.isOrgLoading) return '⏳ Loading org details...';
        if (this.orgLoadError)  return '⚠️ ' + this.orgLoadError;
        if (this.orgsReady)
            return `✅ Source: ${this.sourceOrgName}  →  Target: ${this.targetOrgName}`;
        return '';
    }

    get orgBannerClass() {
        if (this.orgLoadError)
            return 'slds-notify slds-notify_alert slds-theme_error slds-m-bottom_small';
        return 'slds-notify slds-notify_alert slds-theme_info slds-m-bottom_small';
    }

    // ══════════════════════════════════════════════════════════
    // LAYOUT & TAB CSS GETTERS
    // ══════════════════════════════════════════════════════════
    get mainLayoutClass() {
        return this.showPrevCommitPanel
            ? 'slds-grid slds-wrap slds-m-around_medium'
            : 'slds-m-around_medium';
    }
    get mainContentClass()          { return this.showPrevCommitPanel ? 'slds-col slds-has-flexi-truncate' : ''; }
    get findChangesTabClass()       { return this.activeTab === 'findChanges'     ? 'slds-tabs_default__item slds-is-active' : 'slds-tabs_default__item'; }
    get selectedChangesTabClass()   { return this.activeTab === 'selectedChanges' ? 'slds-tabs_default__item slds-is-active' : 'slds-tabs_default__item'; }
    get findChangesPanelClass()     { return this.activeTab === 'findChanges'     ? 'slds-tabs_default__content slds-show' : 'slds-tabs_default__content slds-hide'; }
    get selectedChangesPanelClass() { return this.activeTab === 'selectedChanges' ? 'slds-tabs_default__content slds-show' : 'slds-tabs_default__content slds-hide'; }

    // ══════════════════════════════════════════════════════════
    // COMMIT MODAL GETTERS
    // ══════════════════════════════════════════════════════════
    get hasExistingBranch() {
        return !!this.existingBranchName;
    }

    get existingBranchInfo() {
        if (this.existingBranchName) {
            return `Existing branch: ${this.existingBranchName}`;
        }
        return 'No existing branch found. A new branch will be created automatically.';
    }

    get newBranchToggleLabel() {
        return this.createNewBranch
            ? '🔄 New Branch will be created (existing branch & open PRs will be closed)'
            : '➕ Commit to existing branch';
    }

    get showNewBranchWarning() {
        return this.createNewBranch && this.hasExistingBranch;
    }

    get isModalConfirmDisabled() {
        return this.isModalLoading;
    }

    // ══════════════════════════════════════════════════════════
    // FILTER GETTERS
    // ══════════════════════════════════════════════════════════
    get filteredComponents() {
        let list = this.components;
        if (this.filterName?.trim())          { const q = this.filterName.trim().toLowerCase();          list = list.filter(c => c.name?.toLowerCase().includes(q)); }
        if (this.filterLabel?.trim())         { const q = this.filterLabel.trim().toLowerCase();         list = list.filter(c => c.label?.toLowerCase().includes(q)); }
        if (this.filterCreatedBy?.trim())     { const q = this.filterCreatedBy.trim().toLowerCase();     list = list.filter(c => c.createdBy?.toLowerCase().includes(q)); }
        if (this.filterModifiedBy?.trim())    { const q = this.filterModifiedBy.trim().toLowerCase();    list = list.filter(c => c.lastModifiedBy?.toLowerCase().includes(q)); }
        if (this.filterModifiedAfter?.trim()) { const cutoff = this.filterModifiedAfter.trim();          list = list.filter(c => c.lastModifiedDate && c.lastModifiedDate >= cutoff); }
        if (this.filterCreatedAfter?.trim())  { const cutoff = this.filterCreatedAfter.trim();           list = list.filter(c => c.createdDate && c.createdDate >= cutoff); }
        return list;
    }

    // ══════════════════════════════════════════════════════════
    // PAGINATION GETTERS
    // ══════════════════════════════════════════════════════════
    get paginatedComponents() {
        const start = (this.currentPage - 1) * this.pageSize;
        return this.filteredComponents.slice(start, start + this.pageSize);
    }

    get totalPages() {
        return Math.max(1, Math.ceil(this.filteredComponents.length / this.pageSize));
    }

    get pageStartIndex() {
        if (this.filteredComponents.length === 0) return 0;
        return (this.currentPage - 1) * this.pageSize + 1;
    }

    get pageEndIndex() {
        return Math.min(this.currentPage * this.pageSize, this.filteredComponents.length);
    }

    get hasPrevPage() { return this.currentPage > 1; }
    get hasNextPage() { return this.currentPage < this.totalPages; }
    get isPrevDisabled() { return !this.hasPrevPage; }
get isNextDisabled() { return !this.hasNextPage; }
    get pageSizeOptions() {
        return [
            { label: '10',  value: '10'  },
            { label: '25',  value: '25'  },
            { label: '50',  value: '50'  },
            { label: '100', value: '100' }
        ];
    }

    get currentPageSizeStr() {
        return String(this.pageSize);
    }

    get paginationSummaryText() {
        if (this.filteredComponents.length === 0) return 'No results';
        return `Showing ${this.pageStartIndex}–${this.pageEndIndex} of ${this.filteredComponents.length} components`;
    }

    // ══════════════════════════════════════════════════════════
    // OTHER GETTERS
    // ══════════════════════════════════════════════════════════
    get hasActiveFilters()         { return !!(this.filterName?.trim() || this.filterLabel?.trim() || this.filterCreatedBy?.trim() || this.filterModifiedBy?.trim() || this.filterModifiedAfter?.trim() || this.filterCreatedAfter?.trim()); }
    get noFilteredResults()        { return this.hasComponents && this.filteredComponents.length === 0; }
    get filterSummaryText()        { if (!this.hasComponents) return 'Fetch components to see results'; return `Showing ${this.filteredComponents.length} of ${this.components.length} components`; }
    get hasSelectedComponents()    { return this.selectedComponents.length > 0; }
    get noItemsCheckedInSelected() { return !this.selectedComponents.some(c => c.markedForRemoval); }
    get hasPrevCommits()           { return this.prevCommits.length > 0; }

    // ── Metadata Options ──────────────────────────────────────
    metadataOptions = [
        { label: 'Apex Class',           value: 'ApexClass'                },
        { label: 'Apex Trigger',         value: 'ApexTrigger'              },
        { label: 'LWC',                  value: 'LightningComponentBundle' },
        { label: 'Aura Component',       value: 'AuraDefinitionBundle'     },
        { label: 'Flow',                 value: 'FlowDefinition'           },
        { label: 'Custom Object',        value: 'CustomObject'             },
        { label: 'Validation Rule',      value: 'ValidationRule'           },
        { label: 'Custom Field',         value: 'CustomField'              },
        { label: 'Permission Set',       value: 'PermissionSet'            },
        { label: 'Custom Label',         value: 'CustomLabel'              },
        { label: 'Static Resource',      value: 'StaticResource'           },
        { label: 'Visualforce Page',     value: 'ApexPage'                 },
        { label: 'Email Template',       value: 'EmailTemplate'            },
        { label: 'Custom Metadata Type', value: 'CustomMetadataType'       },
        { label: 'Global Value Set',     value: 'GlobalValueSet'           },
        { label: 'Flexi Page',           value: 'FlexiPage'                }
    ];

    // ══════════════════════════════════════════════════════════
    // FILTER HANDLERS
    // ══════════════════════════════════════════════════════════
    handleFilterChange(event) {
        const filterType = event.target.dataset.filter;
        const value      = event.detail.value;
        if (filterType === 'name')          this.filterName          = value;
        if (filterType === 'label')         this.filterLabel         = value;
        if (filterType === 'createdBy')     this.filterCreatedBy     = value;
        if (filterType === 'modifiedBy')    this.filterModifiedBy    = value;
        if (filterType === 'modifiedAfter') this.filterModifiedAfter = value;
        if (filterType === 'createdAfter')  this.filterCreatedAfter  = value;
        this.currentPage = 1;
    }

    clearFilters() {
        this.filterName = ''; this.filterLabel = ''; this.filterCreatedBy = '';
        this.filterModifiedBy = ''; this.filterModifiedAfter = ''; this.filterCreatedAfter = '';
        this.currentPage = 1;
    }

    // ══════════════════════════════════════════════════════════
    // PAGINATION HANDLERS
    // ══════════════════════════════════════════════════════════
    handlePageSizeChange(event) {
        this.pageSize    = parseInt(event.detail.value, 10);
        this.currentPage = 1;
    }

    goToFirstPage() { this.currentPage = 1; }
    goToPrevPage()  { if (this.hasPrevPage) this.currentPage--; }
    goToNextPage()  { if (this.hasNextPage) this.currentPage++; }
    goToLastPage()  { this.currentPage = this.totalPages; }

    // ══════════════════════════════════════════════════════════
    // PREV COMMITTED PANEL
    // ══════════════════════════════════════════════════════════
    async togglePrevCommitPanel() {
        this.showPrevCommitPanel = !this.showPrevCommitPanel;
        if (this.showPrevCommitPanel) {
            this.prevCommits     = [];
            this.prevCommitError = '';
            await this.loadPreviousCommits();
        }
    }

    async loadPreviousCommits() {
        if (!this.orgsReady && !this.userStoryId) {
            this.prevCommitError = 'User Story not loaded yet.';
            return;
        }
        this.isPrevCommitLoading = true;
        this.prevCommitError     = '';
        try {
            const raw = await getPreviousCommits({ userStoryId: this.userStoryId });
            this.prevCommits = raw.map(pr => {
                const groupedFiles = this.groupPrFiles(pr.files || []);
                return {
                    number     : pr.number,
                    title      : pr.title,
                    mergedAt   : pr.mergedAt,
                    files      : groupedFiles,
                    fileCount  : groupedFiles.length,
                    expanded   : false,
                    expandIcon : 'utility:chevronright'
                };
            });
        } catch (e) {
            this.prevCommitError = this.getError(e);
            this.prevCommits     = [];
        } finally {
            this.isPrevCommitLoading = false;
        }
    }

    groupPrFiles(files) {
        const seen = new Map();
        for (const file of files) {
            const key = file.name;
            if (!seen.has(key)) {
                seen.set(key, {
                    path         : file.path,
                    name         : file.name,
                    metadataType : file.metadataType,
                    fileNames    : [this.getFileName(file.path)]
                });
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

    // ══════════════════════════════════════════════════════════
    // TAB SWITCHING
    // ══════════════════════════════════════════════════════════
    handleTabSwitch(event) { event.preventDefault(); this.activeTab = event.currentTarget.dataset.tab; }
    goToSelectedTab(event) { event.preventDefault(); this.activeTab = 'selectedChanges'; }
    goToFindTab(event)     { event.preventDefault(); this.activeTab = 'findChanges'; }

    // ══════════════════════════════════════════════════════════
    // TYPE CHANGE
    // ══════════════════════════════════════════════════════════
    handleTypeChange(event) {
        this.selectedType  = event.detail.value;
        this.components    = [];
        this.hasComponents = false;
        this.statusMessage = '';
        this.showProgress  = false;
        this.currentPage   = 1;
        this.clearFilters();
    }

    // ══════════════════════════════════════════════════════════
    // FETCH COMPONENTS
    // ══════════════════════════════════════════════════════════
    async fetchComponents() {
        if (!this.selectedType) {
            this.setStatus('Please select a metadata type.', false);
            return;
        }
        if (!this.orgsReady) {
            this.setStatus('Org details not loaded yet. Please wait or check User Story.', false);
            return;
        }
        this.isLoading     = true;
        this.statusMessage = '';
        this.showProgress  = false;
        this.currentPage   = 1;
        try {
            const raw = await getComponentsDynamic({
                metadataType : this.selectedType,
                accessToken  : this.sourceAccessToken,
                instanceUrl  : this.sourceInstanceUrl
            });
            const selectedIds = new Set(this.selectedComponents.map(c => c.id));
            this.components = raw.map(c => ({
                ...c,
                checked               : selectedIds.has(c.id),
                createdByDisplay      : this._truncate(c.createdBy),
                lastModifiedByDisplay : this._truncate(c.lastModifiedBy)
            }));
            this.hasComponents = this.components.length > 0;
            if (!this.hasComponents) this.setStatus('No components found.', false);
        } catch (e) {
            this.setStatus('Fetch Error: ' + this.getError(e), false);
        } finally {
            this.isLoading = false;
        }
    }

    // ══════════════════════════════════════════════════════════
    // SELECTION HANDLERS
    // ══════════════════════════════════════════════════════════
    handleSelection(event) {
        const id      = event.target.dataset.id;
        const name    = event.target.dataset.name;
        const checked = event.target.checked;
        this.components = this.components.map(c => c.id === id ? { ...c, checked } : c);
        if (checked) {
            if (!this.selectedComponents.some(c => c.id === id)) {
                const src = this.components.find(c => c.id === id) || {};
                this.selectedComponents = [...this.selectedComponents, {
                    id, name, metadataType: this.selectedType, markedForRemoval: false, rowNum: 0,
                    label                : src.label || '',
                    createdBy            : src.createdBy || '',
                    lastModifiedBy       : src.lastModifiedBy || '',
                    lastModifiedByDisplay: src.lastModifiedByDisplay || '',
                    lastModifiedDate     : src.lastModifiedDate || '',
                    createdDate          : src.createdDate || ''
                }];
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
                id                   : c.id,
                name                 : c.name,
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
        this.components = this.components.map(c => filteredIds.has(c.id) ? { ...c, checked: false } : c);
    }

    handleRemovalCheck(event) {
        const id = event.target.dataset.id, checked = event.target.checked;
        this.selectedComponents = this.selectedComponents.map(c => c.id === id ? { ...c, markedForRemoval: checked } : c);
    }

    removeCheckedFromSelected() {
        const removedIds = this.selectedComponents.filter(c => c.markedForRemoval).map(c => c.id);
        this.selectedComponents = this.selectedComponents.filter(c => !c.markedForRemoval);
        this._reNumberRows();
        this.components = this.components.map(c => removedIds.includes(c.id) ? { ...c, checked: false } : c);
        if (this.selectedComponents.length === 0) {
            this.statusMessage = ''; this.showProgress = false;
            this.progressValue = 0;  this.progressLabel = '';
        }
    }

    _reNumberRows() {
        this.selectedComponents = this.selectedComponents.map((c, i) => ({ ...c, rowNum: i + 1 }));
    }

    // ══════════════════════════════════════════════════════════
    // CLEAN OBJECT XML
    // ══════════════════════════════════════════════════════════
    cleanObjectXml(xmlStr) {
        const parts  = xmlStr.split('<actionOverrides>');
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

    // ══════════════════════════════════════════════════════════
    // STEP 1: Deploy button click → Open Modal
    // ══════════════════════════════════════════════════════════
    async deploySelected() {
        if (!this.selectedComponents.length) {
            this.setStatus('Please select at least one component.', false);
            return;
        }
        if (!this.jsZipLoaded) {
            this.setStatus('JSZip still loading, please wait...', false);
            return;
        }
        if (!this.orgsReady) {
            this.setStatus('Org details not loaded. Please check User Story.', false);
            return;
        }

        this.isModalLoading     = true;
        this.showCommitModal    = true;
        this.createNewBranch    = false;
        this.existingBranchName = null;

        try {
            const existingBranch = await getExistingBranchForUserStory({
                userStoryId: this.userStoryId
            });
            this.existingBranchName = existingBranch || null;
        } catch (e) {
            console.error('Could not fetch existing branch:', e);
            this.existingBranchName = null;
        } finally {
            this.isModalLoading = false;
        }
    }

    // ══════════════════════════════════════════════════════════
    // Toggle handler: "Create New Branch" switch
    // ══════════════════════════════════════════════════════════
    handleNewBranchToggle(event) {
        this.createNewBranch = event.detail.checked;
    }

    // ══════════════════════════════════════════════════════════
    // Modal Cancel
    // ══════════════════════════════════════════════════════════
    handleModalCancel() {
        this.showCommitModal    = false;
        this.createNewBranch    = false;
        this.existingBranchName = null;
        this.isModalLoading     = false;
    }

    // ══════════════════════════════════════════════════════════
    // Modal Confirm → Actual Deploy Flow
    // ══════════════════════════════════════════════════════════
    async handleModalConfirm() {
        this.showCommitModal = false;
        this.isLoading       = true;
        this.showProgress    = true;

        try {
            // ── Step 0: Dependencies check ────────────────────────────
            this.updateProgress('Step 0/3 — Checking Dependencies...', 2);
            const compIds = this.selectedComponents
                .map(c => c.id)
                .filter(id => id && !id.startsWith('dep_'));

            if (compIds.length > 0 && this.sourceInstanceUrl && this.sourceAccessToken) {
                const deps = await getComponentDependencies({
                    componentIds: compIds,
                    accessToken : this.sourceAccessToken,
                    instanceUrl : this.sourceInstanceUrl
                });
                const newDeps = deps.filter(d =>
                    !this.selectedComponents.some(sc =>
                        sc.name === d.name && sc.metadataType === d.metadataType
                    )
                );
                if (newDeps.length > 0) {
                    const sampleName = `${newDeps[0].metadataType}: ${newDeps[0].name}`;
                    if (window.confirm(
                        `Missing Dependencies Found!\n\n${newDeps.length} components needed ` +
                        `(e.g., ${sampleName}).\n\nAdd them automatically?`
                    )) {
                        const formattedDeps = newDeps.map((d, index) => ({
                            id               : 'dep_' + Date.now() + index,
                            name             : d.name,
                            metadataType     : d.metadataType,
                            markedForRemoval : false,
                            rowNum           : 0,
                            label            : '',
                            createdBy        : '',
                            lastModifiedBy   : '',
                            lastModifiedByDisplay: '',
                            lastModifiedDate : '',
                            createdDate      : ''
                        }));
                        this.selectedComponents = [...this.selectedComponents, ...formattedDeps];
                        this._reNumberRows();
                    }
                }
            } else if (compIds.length > 0) {
                console.warn('Skipping dependency check — sourceInstanceUrl or accessToken is null');
            }

            // ── Step 1: Retrieve from Source Org ─────────────────────
            this.updateProgress('Step 1/3 — Retrieving from Source Org...', 5);
            const rawFiles = await this.batchedRetrieveByType();
            const allFiles = rawFiles.map(f => {
                if (f.path.includes('/objects/') && f.path.endsWith('.object')) {
                    try {
                        const xmlStr = decodeURIComponent(escape(atob(f.content)));
                        return {
                            ...f,
                            content: btoa(unescape(encodeURIComponent(this.cleanObjectXml(xmlStr))))
                        };
                    } catch (e) { return f; }
                }
                return f;
            });

            // ── Step 2: Branch setup ──────────────────────────────────
            this.updateProgress('Step 2/3 — Setting up GitHub branch...', 35);
            let branchName;

            if (this.createNewBranch && this.existingBranchName) {
                this.updateProgress('Deleting existing branch & closing open PRs...', 38);
                await deleteFeatureBranchAndClosePR({
                    branchName  : this.existingBranchName,
                    userStoryId : this.userStoryId
                });
                this.updateProgress('Creating new branch...', 42);
                branchName = await this.setupGitBranch();
            } else if (!this.existingBranchName) {
                branchName = await this.setupGitBranch();
            } else {
                branchName = this.existingBranchName;
            }

            // ── Step 3: Push to GitHub ────────────────────────────────
            this.updateProgress('Step 2/3 — Pushing to GitHub...', 50);
            const packageXml     = this.buildOrderedPackageXml();
            const allFilesToPush = [
                { path: 'package.xml', content: btoa(unescape(encodeURIComponent(packageXml))) },
                ...allFiles.filter(f => f.path !== 'package.xml')
            ];

            const commitSha = await this.pushAllFilesWithRetry(allFilesToPush, branchName);

            // ── Step 4: Save Salesforce records ───────────────────────
            this.updateProgress('Step 3/3 — Saving commit records in Salesforce...', 80);

            const componentData = this.selectedComponents.map(c => ({
                name        : c.name,
                metadataType: c.metadataType
            }));

            const uniqueTypes = [...new Set(this.selectedComponents.map(c => c.metadataType))].join(', ');
            const commitMsg   = `Deploy: ${uniqueTypes} — ${this.selectedComponents.length} components`;

            await saveCommitAndComponentRecords({
                commitSha    : commitSha,
                commitMessage: commitMsg,
                branchName   : branchName,
                userStoryId  : this.userStoryId,
                components   : componentData
            });

            // ── Final Status ──────────────────────────────────────────
            this.updateProgress(
                `✅ Done! ${this.selectedComponents.length} components committed to GitHub`,
                100
            );
            this.setStatus(
                `✅ Successfully pushed ${this.selectedComponents.length} components to GitHub and saved records!`,
                true
            );

            if (this.showPrevCommitPanel) {
                this.prevCommits     = [];
                this.prevCommitError = '';
                await this.loadPreviousCommits();
            }

        } catch (e) {
            this.setStatus('Error: ' + this.getError(e), false);
            this.showProgress = false;
        } finally {
            this.isLoading          = false;
            this.createNewBranch    = false;
            this.existingBranchName = null;
        }
    }

    // ══════════════════════════════════════════════════════════
    // BUILD ORDERED PACKAGE XML
    // ══════════════════════════════════════════════════════════
    buildOrderedPackageXml() {
        const DEPLOY_ORDER = {
            'CustomObject'           : 1,  'CustomField'             : 2,
            'ValidationRule'         : 3,  'GlobalValueSet'          : 4,
            'CustomLabel'            : 5,  'StaticResource'          : 6,
            'ApexClass'              : 7,  'ApexTrigger'             : 8,
            'ApexPage'               : 9,  'LightningComponentBundle': 10,
            'AuraDefinitionBundle'   : 11, 'FlowDefinition'          : 12,
            'PermissionSet'          : 13, 'EmailTemplate'           : 14,
            'FlexiPage'              : 15
        };
        const byType = {};
        for (const comp of this.selectedComponents) {
            const type = comp.metadataType, name = comp.name;
            if (SKIP_COMPONENTS.includes(name)) continue;
            if ((type === 'CustomObject' || type === 'CustomMetadataType') &&
                !name.endsWith('__c') && !name.endsWith('__mdt')) continue;
            if (!byType[type]) byType[type] = [];
            if (!byType[type].includes(name)) byType[type].push(name);
        }
        const sortedTypes = Object.keys(byType).sort((a, b) =>
            (DEPLOY_ORDER[a] || 99) - (DEPLOY_ORDER[b] || 99)
        );
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

    // ══════════════════════════════════════════════════════════
    // BATCHED RETRIEVE
    // ══════════════════════════════════════════════════════════
    async batchedRetrieveByType() {
        const byType = {};
        for (const comp of this.selectedComponents) {
            if (!byType[comp.metadataType]) byType[comp.metadataType] = [];
            byType[comp.metadataType].push(comp.name);
        }
        const types        = Object.keys(byType);
        const allFiles     = new Map();
        let   totalDone    = 0;
        let   succeeded    = 0;
        const totalBatches = types.reduce((sum, t) =>
            sum + Math.ceil(byType[t].length / RETRIEVE_BATCH_SIZE), 0
        );

        for (const metadataType of types) {
            const batches = this.chunkArray(byType[metadataType], RETRIEVE_BATCH_SIZE);
            for (let i = 0; i < batches.length; i++) {
                totalDone++;
                this.updateProgress(
                    `Retrieving ${metadataType} — batch ${i + 1}/${batches.length}...`,
                    5 + Math.round((totalDone / totalBatches) * 25)
                );
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
        const jobId = await startRetrieveDynamic({
            componentNames,
            metadataType,
            accessToken : this.sourceAccessToken,
            instanceUrl : this.sourceInstanceUrl
        });
        for (let i = 0; i < MAX_POLL_ATTEMPTS; i++) {
            await this.sleep(POLL_INTERVAL_MS);
            const result = await checkRetrieveStatusDynamic({
                jobId,
                accessToken : this.sourceAccessToken,
                instanceUrl : this.sourceInstanceUrl
            });
            if (result.status === 'Succeeded') return result.zip;
            if (result.status === 'Failed') throw new Error('Retrieve failed: ' + result.message);
        }
        throw new Error('Retrieve timed out after 2 minutes.');
    }

    async unzipFiles(base64Zip, metadataType) {
        const binary = atob(base64Zip);
        const bytes  = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        const zip          = await JSZip.loadAsync(bytes);
        const files        = [];
        const SKIP_FOLDERS = ['layouts', 'profiles'];
        const SKIP_FILES   = [
            'OAuthCallbackCtrl.cls',
            'OAuthCallbackCtrl.cls-meta.xml',
            'OAuthCallback.page',
            'OAuthCallback.page-meta.xml'
        ];

        for (const [filename, fileObj] of Object.entries(zip.files)) {
            if (!fileObj.dir) {
                let cleanPath = filename.replace(/^unpackaged\//, '');
                if (cleanPath.endsWith('.flexipage')) cleanPath = cleanPath + '-meta.xml';

                const fileName = cleanPath.split('/').pop();
                if (SKIP_FILES.some(skip => fileName === skip)) continue;

                const shouldSkip = SKIP_FOLDERS.some(folder =>
                    cleanPath.includes(`/${folder}/`) || cleanPath.startsWith(`${folder}/`)
                );
                if (shouldSkip) continue;
                if (cleanPath.endsWith('.object')) {
                    let xmlStr = await fileObj.async('string');
                    if (cleanPath.endsWith('__mdt.object') && !xmlStr.includes('<label>')) {
                        const rawName       = cleanPath.split('/').pop().replace('__mdt.object', '');
                        const labelName     = rawName.replace(/_/g, ' ');
                        const fieldsRegex   = /<fields>[\s\S]*?<\/fields>/g;
                        const fieldsMatch   = xmlStr.match(fieldsRegex);
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

    // ══════════════════════════════════════════════════════════
    // GIT BRANCH SETUP
    // ══════════════════════════════════════════════════════════
    async setupGitBranch() {
        const sha        = await getMainBranchSha({ userStoryId: this.userStoryId });
        const usName     = await getUserStoryName({ userStoryId: this.userStoryId });
        const safeName   = (usName || 'US').replace(/[^a-zA-Z0-9-]/g, '-');
        const branchName = `feature/${safeName}`;
        await createFeatureBranch({ branchName, sha, userStoryId: this.userStoryId });
        return branchName;
    }

    // ══════════════════════════════════════════════════════════
    // PUSH FILES — Returns commit SHA
    // ══════════════════════════════════════════════════════════
    async pushAllFilesWithRetry(files, branchName) {
        const uniqueTypes = [...new Set(this.selectedComponents.map(c => c.metadataType))].join(', ');
        const commitMsg   = `Deploy: ${uniqueTypes} — ${this.selectedComponents.length} components`;
        this.updateProgress(`Pushing all ${files.length} files to GitHub...`, 50);
        try {
            const commitSha = await pushMultipleFilesToGitHub({
                branchName,
                commitMessage : commitMsg,
                files         : files.map(f => ({ filePath: f.path, base64Content: f.content })),
                userStoryId   : this.userStoryId
            });
            return commitSha;
        } catch (error) {
            throw new Error('Bulk push failed: ' + this.getError(error));
        }
    }

    // ══════════════════════════════════════════════════════════
    // UTILITIES
    // ══════════════════════════════════════════════════════════
    _truncate(str)        { if (!str) return ''; return str.length > NAME_DISPLAY_MAX ? str.substring(0, NAME_DISPLAY_MAX) + '...' : str; }
    chunkArray(arr, size) { const chunks = []; for (let i = 0; i < arr.length; i += size) chunks.push(arr.slice(i, i + size)); return chunks; }
    updateProgress(label, value) {
        this.progressLabel = label;
        this.progressValue = value;
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