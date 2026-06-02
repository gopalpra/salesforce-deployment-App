import { LightningElement, api, track } from 'lwc';
import { NavigationMixin }              from 'lightning/navigation';
import { loadScript }                   from 'lightning/platformResourceLoader';
import JSZIP                            from '@salesforce/resourceUrl/JSZip';

import getActiveCommitInfo  from '@salesforce/apex/PromotionCtrl.getActiveCommitInfo';
import getOrgDetails        from '@salesforce/apex/PromotionCtrl.getOrgDetails';
import refreshToken         from '@salesforce/apex/PromotionCtrl.refreshToken';
import getGitHubBranchZip   from '@salesforce/apex/PromotionCtrl.getGitHubBranchZip';
import getFileContent       from '@salesforce/apex/PromotionCtrl.getFileContent';
import startValidate        from '@salesforce/apex/PromotionCtrl.startValidate';
import checkValidateStatus  from '@salesforce/apex/PromotionCtrl.checkValidateStatus';
import savePromotion        from '@salesforce/apex/PromotionCtrl.savePromotion';

const MAX_POLL  = 80;
const POLL_MS   = 5000;

export default class ValidateForPromotion extends NavigationMixin(LightningElement) {

    @api recordId;

    @track isInitializing        = true;
    @track isLoading             = false;
    @track isValidating          = false;
    @track hasActiveCommit       = false;
    @track activeCommitBranch    = '';
    @track activeCommitMessage   = '';
    @track activeCommitSha       = '';
    @track errorMessage          = '';
    @track statusMessage         = '';
    @track statusClass           = 'slds-text-color_success';
    @track validationStatusLabel = 'Preparing...';
    @track componentsDone        = 0;
    @track componentsTotal       = 0;
    @track showComponentProgress = false;

    // Org / GitHub
    targetAccessToken = null;
    targetInstanceUrl = null;
    repoOwner         = '';
    repoName          = '';
    githubToken       = '';

    jsZipLoaded = false;

    // ══════════════════════════════════════════════════════════
    // LIFECYCLE
    // ══════════════════════════════════════════════════════════
    async connectedCallback() {
        try {
            await loadScript(this, JSZIP);
            this.jsZipLoaded = true;
        } catch (e) {
            console.error('JSZip load failed:', e);
        }
        await this.initialize();
    }

    // ══════════════════════════════════════════════════════════
    // INITIALIZE
    // ══════════════════════════════════════════════════════════
    async initialize() {
        this.isInitializing = true;
        try {
            const commitInfo = await getActiveCommitInfo({ userStoryId: this.recordId });
            this.hasActiveCommit     = commitInfo.hasActiveCommit;
            if (!this.hasActiveCommit) return;

            this.activeCommitBranch  = commitInfo.branchName   || '';
            this.activeCommitMessage = commitInfo.commitMessage || '';
            this.activeCommitSha     = commitInfo.commitSha    || '';

            const orgDetails = await getOrgDetails({ userStoryId: this.recordId });
            this.repoOwner   = orgDetails.repoOwner;
            this.repoName    = orgDetails.repoName;
            this.githubToken = orgDetails.githubToken;

            const tokenData = await refreshToken({
                refreshToken : orgDetails.targetRefreshToken,
                orgType      : orgDetails.targetOrgType,
                orgName      : orgDetails.targetOrgName
            });
            this.targetAccessToken = tokenData.accessToken;
            this.targetInstanceUrl = tokenData.instanceUrl;

        } catch (e) {
            this.errorMessage = this.getError(e);
        } finally {
            this.isInitializing = false;
        }
    }

    // ══════════════════════════════════════════════════════════
    // GETTERS
    // ══════════════════════════════════════════════════════════
    get validationProgressValue() {
        if (!this.componentsTotal) return 10;
        return Math.round((this.componentsDone / this.componentsTotal) * 100);
    }

    // ══════════════════════════════════════════════════════════
    // VALIDATE HANDLER
    // ══════════════════════════════════════════════════════════
    async handleValidate() {
        if (!this.jsZipLoaded) {
            this.errorMessage = 'JSZip still loading, please wait...';
            return;
        }
        this.isValidating          = true;
        this.isLoading             = true;
        this.errorMessage          = '';
        this.statusMessage         = '';
        this.showComponentProgress = false;

        try {
            // Step 1: Get file list from GitHub branch
            this.validationStatusLabel = '📂 Fetching files from GitHub...';
            const branchDataStr = await getGitHubBranchZip({
                repoOwner   : this.repoOwner,
                repoName    : this.repoName,
                githubToken : this.githubToken,
                branchName  : this.activeCommitBranch,
                userStoryId : this.recordId
            });
            const branchData = JSON.parse(branchDataStr);
            const files      = branchData.files              || [];
            const allActiveComponents = branchData.allActiveComponents || [];

            if (!files.length) throw new Error('No files found in branch: ' + this.activeCommitBranch);

            // Step 2: Build ZIP using JSZip
            this.validationStatusLabel = '📦 Building ZIP...';
            const zip = new JSZip();

            // Fetch file contents in batches
            const BATCH = 5;
            for (let i = 0; i < files.length; i += BATCH) {
                const batch = files.slice(i, i + BATCH);
                await Promise.all(batch.map(async (file) => {
                    try {
                        const content = await getFileContent({
                            repoOwner   : this.repoOwner,
                            repoName    : this.repoName,
                            githubToken : this.githubToken,
                            fileSha     : file.sha
                        });
                        zip.file(file.path, content, { base64: true });
                    } catch (e) {
                        console.warn('File fetch failed:', file.path, e);
                    }
                }));
                this.validationStatusLabel = `📦 Loading files... ${Math.min(i + BATCH, files.length)}/${files.length}`;
            }

            // ✅ Build package.xml from allActiveComponents
            const typeMap = {};
            for (const comp of allActiveComponents) {
                const mdType = comp.Metadata_Type__c || 'ApexClass';
                if (!typeMap[mdType]) typeMap[mdType] = [];
                typeMap[mdType].push(comp.Component_Name__c);
            }

            let typesXml = '';
            for (const [mdType, members] of Object.entries(typeMap)) {
                typesXml += `<types>`;
                for (const m of members) {
                    typesXml += `<members>${m}</members>`;
                }
                typesXml += `<name>${mdType}</name></types>`;
            }

            const packageXml = `<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
    ${typesXml}
    <version>64.0</version>
</Package>`;

            // ✅ Add package.xml to ZIP root
            zip.file('package.xml', packageXml);

            // Step 3: Generate ZIP as base64
            this.validationStatusLabel = '📤 Sending to Salesforce for validation...';
            const zipBase64 = await zip.generateAsync({ type: 'base64' });

            // Step 4: Start validation
            const jobId = await startValidate({
                zipBase64   : zipBase64,
                accessToken : this.targetAccessToken,
                instanceUrl : this.targetInstanceUrl
            });

            // Step 5: Poll status
            this.validationStatusLabel = '⏳ Validating...';
            const result = await this.pollValidation(jobId);

            // Step 6: Save Promotion record
            this.validationStatusLabel = '💾 Saving promotion record...';
            const totalComponents = files.filter(f => !f.path.endsWith('package.xml')).length;
            const errorMsg        = result.errors && result.errors.length
                ? result.errors.map(e => `${e.fileName} (Line ${e.lineNumber}): ${e.problem}`).join('\n')
                : '';

            const promotionId = await savePromotion({
                userStoryId     : this.recordId,
                status          : result.success ? 'Validated' : 'Validation Failed',
                featureBranch   : this.activeCommitBranch,
                commitSha       : this.activeCommitSha,
                totalComponents : totalComponents,
                testsRun        : result.testsRun    || 0,
                testsPassed     : result.testsPassed || 0,
                testsFailed     : result.testsFailed || 0,
                errorMessage    : errorMsg,
                jobId           : jobId
            });

            if (result.success) {
                this[NavigationMixin.Navigate]({
                    type       : 'standard__recordPage',
                    attributes : {
                        recordId      : promotionId,
                        objectApiName : 'Promotion__c',
                        actionName    : 'view'
                    }
                });
            } else {
                this.errorMessage = errorMsg || 'Validation failed. Please check errors.';
                this.isValidating = false;
            }

        } catch (e) {
            this.errorMessage = this.getError(e);
            this.isValidating = false;
        } finally {
            this.isLoading = false;
        }
    }

    // ══════════════════════════════════════════════════════════
    // POLL VALIDATION STATUS
    // ══════════════════════════════════════════════════════════
    async pollValidation(jobId) {
        for (let i = 0; i < MAX_POLL; i++) {
            await this.sleep(POLL_MS);
            const result = await checkValidateStatus({
                jobId       : jobId,
                accessToken : this.targetAccessToken,
                instanceUrl : this.targetInstanceUrl
            });

            if (result.status === 'InProgress') {
                this.componentsDone        = result.componentsDone  || 0;
                this.componentsTotal       = result.componentsTotal || 0;
                this.showComponentProgress = this.componentsTotal > 0;
                this.validationStatusLabel = result.stateDetail || 'Validating...';
                continue;
            }
            return result;
        }
        throw new Error('Validation timed out. Please try again.');
    }

    // ══════════════════════════════════════════════════════════
    // UTILITIES
    // ══════════════════════════════════════════════════════════
    getError(e) { return e?.body?.message || e?.message || JSON.stringify(e); }
    sleep(ms)   { return new Promise(r => setTimeout(r, ms)); }
}