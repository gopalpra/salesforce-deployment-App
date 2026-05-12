import { LightningElement, api } from 'lwc';
import { NavigationMixin } from 'lightning/navigation';

export default class CommitButton extends NavigationMixin(LightningElement) {
    
    @api recordId;

    handleCommit() {
        this[NavigationMixin.Navigate]({
            type: 'standard__navItemPage',
            attributes: {
                apiName: 'Deployment' 
            },
            state: {
                c__userStoryId: this.recordId
            }
        });
    }
}