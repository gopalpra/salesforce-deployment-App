import { LightningElement, api, track } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';
import getPipelineDetail from '@salesforce/apex/PipelineController.getPipelineDetail';

export default class CommitButton extends NavigationMixin(LightningElement) {

    @api recordId;
    @track pipeline;
    @track isLoading  = true;
    @track errorMessage = '';

    connectedCallback() {
        this.loadPipeline();
    }

    async loadPipeline() {
        this.isLoading    = true;
        this.errorMessage = '';
        try {
            const result = await getPipelineDetail({ 
                pipelineId: this.recordId 
            });
            this.pipeline = result;
        } catch(e) {
            this.errorMessage = e?.body?.message || e?.message || 'Error loading pipeline';
            console.error('Pipeline load error:', e);
        } finally {
            this.isLoading = false;
        }
    }

    get hasPipeline()   { return !!this.pipeline; }
    get hasError()      { return !!this.errorMessage; }
    get sourceOrgName() { return this.pipeline?.Source_Org__r?.Name || ''; }
    get targetOrgName() { return this.pipeline?.Target_Org__r?.Name || ''; }
    get sourceBranch()  { return this.pipeline?.Source_Branch__c || ''; }
    get targetBranch()  { return this.pipeline?.Target_Branch__c || ''; }
    get jiraId()        { return this.pipeline?.Jira_Id__c || ''; }

    get statusBadgeClass() {
        const s = this.pipeline?.Status__c;
        if (s === 'Deployed') return 'slds-badge slds-theme_success';
        if (s === 'Active')   return 'slds-badge slds-theme_warning';
        return 'slds-badge';
    }

    handleCommit() {
        if (!this.pipeline) return;

        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: {
                apiName: 'Deployment'
            },
            state: {
                c__pipelineId  : this.pipeline.Id,
                c__sourceOrgId : this.pipeline.Source_Org__c,
                c__targetOrgId : this.pipeline.Target_Org__c,
                c__sourceBranch: this.pipeline.Source_Branch__c,
                c__targetBranch: this.pipeline.Target_Branch__c
            }
        });
    }
}