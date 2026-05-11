import { LightningElement, track } from 'lwc';
import getEnvironments from '@salesforce/apex/PipelineController.getEnvironments';
import savePipeline    from '@salesforce/apex/PipelineController.savePipeline';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';

export default class PipelineForm extends LightningElement {

    @track pipelineName  = '';
    @track sourceOrgId   = '';
    @track targetOrgId   = '';
    @track sourceBranch  = '';
    @track targetBranch  = '';
    @track jiraId        = '';
    @track status        = 'Draft';
    @track envOptions    = [];

    statusOptions = [
        { label: 'Draft',    value: 'Draft'    },
        { label: 'Active',   value: 'Active'   },
        { label: 'Deployed', value: 'Deployed' }
    ];

   
    connectedCallback() {
        getEnvironments()
            .then(result => {
                this.envOptions = result.map(env => ({
                    label: env.Org_Name__c,
                    value: env.Id
                }));
            })
            .catch(error => {
                console.error('Error fetching environments:', error);
            });
    }

    handleName(e)         { this.pipelineName = e.detail.value; }
    handleSourceOrg(e)    { this.sourceOrgId  = e.detail.value; }
    handleSourceBranch(e) { this.sourceBranch = e.detail.value; }
    handleTargetOrg(e)    { this.targetOrgId  = e.detail.value; }
    handleTargetBranch(e) { this.targetBranch = e.detail.value; }
    handleJiraId(e)       { this.jiraId       = e.detail.value; }
    handleStatus(e)       { this.status       = e.detail.value; }

    handleSave() {
        // Validation
        if (!this.pipelineName || !this.sourceOrgId || !this.targetOrgId) {
            this.dispatchEvent(new ShowToastEvent({
                title:   'Error',
                message: 'Name, Source Org aur Target Org required hain!',
                variant: 'error'
            }));
            return;
        }

        // Save
        savePipeline({
            name:         this.pipelineName,
            sourceOrgId:  this.sourceOrgId,
            targetOrgId:  this.targetOrgId,
            sourceBranch: this.sourceBranch,
            targetBranch: this.targetBranch,
            jiraId:       this.jiraId,
            status:       this.status
        })
        .then(() => {
            this.dispatchEvent(new ShowToastEvent({
                title:   'Success',
                message: 'Pipeline has been saved successfully!',
                variant: 'success'
            }));
        })
        .catch(error => {
            console.error('Error saving pipeline:', error);
        });
    }
}