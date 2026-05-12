import { LightningElement, track, api } from 'lwc';
import { CurrentPageReference } from 'lightning/navigation';
import { wire } from 'lwc';
import { loadScript } from 'lightning/platformResourceLoader';
import JSZIP from '@salesforce/resourceUrl/JSZip';

import getComponentsForOrg  from '@salesforce/apex/PipelineController.getComponentsForOrg';
import getPipelineDetail    from '@salesforce/apex/PipelineController.getPipelineDetail';

// Reuse existing deploy methods tumhare DeploymentToolCtrl se
import startRetrieve        from '@salesforce/apex/DeploymentToolCtrl.startRetrieve';
import checkRetrieveStatus  from '@salesforce/apex/DeploymentToolCtrl.checkRetrieveStatus';
import getMainBranchSha     from '@salesforce/apex/DeploymentToolCtrl.getMainBranchSha';
import createFeatureBranch  from '@salesforce/apex/DeploymentToolCtrl.createFeatureBranch';
import pushMultipleFilesToGitHub from '@salesforce/apex/DeploymentToolCtrl.pushMultipleFilesToGitHub';
import createPullRequest    from '@salesforce/apex/DeploymentToolCtrl.createPullRequest';
import mergePullRequest     from '@salesforce/apex/DeploymentToolCtrl.mergePullRequest';
import saveDeploymentLog    from '@salesforce/apex/DeploymentToolCtrl.saveDeploymentLog';
import syncDeploymentStatus from '@salesforce/apex/DeploymentToolCtrl.syncDeploymentStatus';

const POLL_INTERVAL_MS       = 5000;
const MAX_POLL_ATTEMPTS      = 80;
const WORKFLOW_POLL_INTERVAL = 30000;
const WORKFLOW_MAX_ATTEMPTS  = 20;

export default class DeploymentPage extends LightningElement {

    // URL params se aayega
    @track pipelineId;
    @track sourceOrgId;
    @track targetOrgId;
    @track sourceBranch;
    @track targetBranch;
    @track sourceOrgName;
    @track targetOrgName;

    @track selectedType   = '';
    @track components     = [];
    @track isLoading      = false;
    @track statusMessage  = '';
    @track statusClass    = 'slds-text-color_success';
    @track showProgress   = false;
    @track progressValue  = 0;
    @track progressLabel  = '';

    jsZipLoaded = false;

    // URL params read karo
    @wire(CurrentPageReference)
    setPageRef(pageRef) {
        if (pageRef?.state) {
            this.pipelineId   = pageRef.state.c__pipelineId;
            this.sourceOrgId  = pageRef.state.c__sourceOrgId;
            this.targetOrgId  = pageRef.state.c__targetOrgId;
            this.sourceBranch = pageRef.state.c__sourceBranch;
            this.targetBranch = pageRef.state.c__targetBranch;
            this.loadPipelineNames();
        }
    }

    connectedCallback() {
        loadScript(this, JSZIP)
            .then(() => { this.jsZipLoaded = true; })
            .catch(err => console.error('JSZip load failed:', err));
    }

    async loadPipelineNames() {
        try {
            const pipeline = await getPipelineDetail({ pipelineId: this.pipelineId });
            this.sourceOrgName = pipeline.Source_Org__r.Name;
            this.targetOrgName = pipeline.Target_Org__r.Name;
        } catch(e) {
            console.error('Pipeline load error:', e);
        }
    }

    get hasComponents() { return this.components.length > 0; }
    get hasSelected()   { return this.components.some(c => c.checked); }
    get selectedCount() { return this.components.filter(c => c.checked).length; }

    metadataOptions = [
        { label: 'Apex Class',            value: 'ApexClass'                },
        { label: 'Apex Trigger',          value: 'ApexTrigger'              },
        { label: 'LWC',                   value: 'LightningComponentBundle'  },
        { label: 'Aura Component',        value: 'AuraDefinitionBundle'     },
        { label: 'Flow',                  value: 'FlowDefinition'           },
        { label: 'Custom Object',         value: 'CustomObject'             },
        { label: 'Custom Field',          value: 'CustomField'              },
        { label: 'Validation Rule',       value: 'ValidationRule'           },
        { label: 'Permission Set',        value: 'PermissionSet'            },
        { label: 'Static Resource',       value: 'StaticResource'           },
        { label: 'Visualforce Page',      value: 'ApexPage'                 },
        { label: 'Custom Metadata Type',  value: 'CustomMetadataType'       },
        { label: 'Flexi Page',            value: 'FlexiPage'                }
    ];

    handleTypeChange(event) {
        this.selectedType = event.detail.value;
        this.components   = [];
    }

    // Source Org se metadata fetch karo
    async fetchMetadata() {
        if (!this.selectedType) {
            this.setStatus('Pehle Metadata Type select karo!', false);
            return;
        }
        this.isLoading    = true;
        this.statusMessage = 'Source Org se metadata fetch ho raha hai...';
        try {
            const raw = await getComponentsForOrg({
                metadataType : this.selectedType,
                orgId        : this.sourceOrgId
            });
            this.components = raw.map(c => ({ ...c, checked: false }));
            if (!this.components.length) {
                this.setStatus('Koi component nahi mila!', false);
            }
        } catch(e) {
            this.setStatus('Fetch Error: ' + this.getError(e), false);
        } finally {
            this.isLoading     = false;
            this.statusMessage = '';
        }
    }

    handleSelection(event) {
        const id      = event.target.dataset.id;
        const checked = event.target.checked;
        this.components = this.components.map(c =>
            c.id === id ? { ...c, checked } : c
        );
    }

    selectAll()   { this.components = this.components.map(c => ({ ...c, checked: true  })); }
    deselectAll() { this.components = this.components.map(c => ({ ...c, checked: false })); }

    // Deploy to Target Org
    async handleDeploy() {
        const selected = this.components.filter(c => c.checked);
        if (!selected.length) {
            this.setStatus('Koi component select nahi kiya!', false);
            return;
        }
        if (!this.jsZipLoaded) {
            this.setStatus('JSZip load ho raha hai, thoda wait karo...', false);
            return;
        }

        this.isLoading   = true;
        this.showProgress = true;

        try {
            // Step 1: Retrieve
            this.updateProgress('Step 1/4 — Source Org se retrieve ho raha hai...', 10);
            const jobId = await startRetrieve({
                componentNames: selected.map(c => c.name),
                metadataType  : this.selectedType
            });

            let zipBase64;
            for (let i = 0; i < MAX_POLL_ATTEMPTS; i++) {
                await this.sleep(POLL_INTERVAL_MS);
                const result = await checkRetrieveStatus({ jobId });
                if (result.status === 'Succeeded') { zipBase64 = result.zip; break; }
                if (result.status === 'Failed') throw new Error('Retrieve failed: ' + result.message);
            }
            if (!zipBase64) throw new Error('Retrieve timeout!');

            // Step 2: GitHub Branch
            this.updateProgress('Step 2/4 — GitHub branch ban rahi hai...', 35);
            const sha        = await getMainBranchSha();
            const branchName = `deploy/pipeline-${this.pipelineId}-${Date.now()}`;
            await createFeatureBranch({ branchName, sha });

            // Step 3: Push to GitHub
            this.updateProgress('Step 3/4 — Files GitHub pe push ho rahi hain...', 55);
            const files = await this.unzipFiles(zipBase64);
            const packageXml = this.buildPackageXml(selected);
            const allFiles = [
                { filePath: 'package.xml', base64Content: btoa(unescape(encodeURIComponent(packageXml))) },
                ...files.map(f => ({ filePath: f.path, base64Content: f.content }))
            ];
            await pushMultipleFilesToGitHub({
                branchName,
                commitMessage: `Pipeline Deploy: ${selected.length} ${this.selectedType} components`,
                files        : allFiles
            });

            // Step 4: PR + Merge
            this.updateProgress('Step 4/4 — PR create aur merge ho rahi hai...', 75);
            const title    = `Pipeline Deploy: ${this.selectedType} (${selected.length} components)`;
            const prNumber = await createPullRequest({ branchName, title });
            await mergePullRequest({ prNumber });

            const logId = await saveDeploymentLog({
                prNumber,
                prTitle   : title,
                branchName,
                components: selected.map(c => ({
                    name        : c.name,
                    metadataType: this.selectedType,
                    filePath    : '',
                    operation   : 'Deploy'
                }))
            });

            // Poll workflow
            this.updateProgress('GitHub Actions ka wait kar rahe hain...', 85);
            const finalStatus = await this.pollWorkflowStatus(logId, branchName);

            if (finalStatus === 'Deployed') {
                this.updateProgress(`✅ Deploy successful! PR #${prNumber}`, 100);
                this.setStatus(`${selected.length} components Target Org mein deploy ho gaye! PR #${prNumber}`, true);
            } else {
                this.setStatus(`PR #${prNumber} merge hua lekin GitHub Actions fail hua. Logs check karo.`, false);
            }

        } catch(e) {
            this.setStatus('Deploy Error: ' + this.getError(e), false);
            this.showProgress = false;
        } finally {
            this.isLoading = false;
        }
    }

    buildPackageXml(selected) {
        const names = selected.map(c => `    <members>${c.name}</members>`).join('\n');
        let type = this.selectedType;
        if (type === 'FlowDefinition') type = 'Flow';
        return `<?xml version="1.0" encoding="UTF-8"?>
<Package xmlns="http://soap.sforce.com/2006/04/metadata">
  <types>
${names}
    <name>${type}</name>
  </types>
  <version>64.0</version>
</Package>`;
    }

    async unzipFiles(base64Zip) {
        const binary = atob(base64Zip);
        const bytes  = new Uint8Array(binary.length);
        for (let i = 0; i < binary.length; i++) bytes[i] = binary.charCodeAt(i);
        const zip   = await JSZip.loadAsync(bytes);
        const files = [];
        for (const [filename, fileObj] of Object.entries(zip.files)) {
            if (!fileObj.dir) {
                const cleanPath = filename.replace(/^unpackaged\//, '');
                files.push({ path: cleanPath, content: await fileObj.async('base64') });
            }
        }
        return files;
    }

    async pollWorkflowStatus(logId, branchName) {
        for (let i = 0; i < WORKFLOW_MAX_ATTEMPTS; i++) {
            await this.sleep(WORKFLOW_POLL_INTERVAL);
            const status = await syncDeploymentStatus({ logId, branchName });
            if (status === 'Deployed' || status === 'Failed') return status;
        }
        return 'Failed';
    }

    updateProgress(label, value) {
        this.progressLabel = label;
        this.progressValue = value;
        this.statusMessage = label;
    }
    setStatus(msg, isSuccess) {
        this.statusMessage = msg;
        this.statusClass   = isSuccess ? 'slds-text-color_success' : 'slds-text-color_error';
    }
    getError(e) { return e?.body?.message || e?.message || JSON.stringify(e); }
    sleep(ms)   { return new Promise(resolve => setTimeout(resolve, ms)); }
}