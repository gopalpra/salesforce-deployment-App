import { LightningElement, api, track } from 'lwc';
import createPRForUserStory from '@salesforce/apex/DeploymentToolCtrl.createPRForUserStory';

export default class OpenPullRequestButton extends LightningElement {

    @api recordId;

    @track isLoading    = false;
    @track errorMessage = '';

    get buttonLabel() {
        return this.isLoading ? 'Please wait...' : 'Open Pull Request';
    }

    async handleOpenPR() {
        if (!this.recordId) {
            this.errorMessage = 'Record ID not found. Please refresh the page';
            return;
        }
        this.isLoading    = true;
        this.errorMessage = '';
        try {
            const result = await createPRForUserStory({
                userStoryId: this.recordId
            });
            if (result && result.url) {
                window.open(result.url, '_blank');
            } else {
                this.errorMessage = 'URL not found. Please try again.';
            }
        } catch (e) {
            this.errorMessage =
                e?.body?.message || e?.message || 'Something went wrong.';
        } finally {
            this.isLoading = false;
        }
    }
}