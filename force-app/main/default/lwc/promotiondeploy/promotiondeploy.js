import { LightningElement, api, track, wire } from 'lwc';
import { refreshApex }                        from '@salesforce/apex';
import getPromotionDetails   from '@salesforce/apex/PromotionCtrl.getPromotionDetails';
import createPromotionBranch from '@salesforce/apex/PromotionCtrl.createPromotionBranch';

export default class PromotionDeploy extends LightningElement {

    @api recordId; // Promotion__c Id

    @track isLoading        = true;
    @track isDeploying      = false;
    @track promotionLoaded  = false;
    @track errorMessage     = '';
    @track deployStatusLabel = '🔀 Creating promotion branch...';

    // Promotion data
    @track promotionStatus   = '';
    @track featureBranch     = '';
    @track promotionBranch   = '';
    @track totalComponents   = 0;
    @track validatedBy       = '';
    @track validatedAt       = '';
    @track canDeploy         = false;
    @track isDeployed        = false;
    @track userStoryId       = '';

    // ══════════════════════════════════════════════════════════
    // LIFECYCLE
    // ══════════════════════════════════════════════════════════
    async connectedCallback() {
        await this.loadPromotion();
    }

    // ══════════════════════════════════════════════════════════
    // LOAD PROMOTION DETAILS
    // ══════════════════════════════════════════════════════════
    async loadPromotion() {
        this.isLoading = true;
        try {
            const data = await getPromotionDetails({ promotionId: this.recordId });
            this.promotionStatus  = data.status           || '';
            this.featureBranch    = data.featureBranch    || '';
            this.promotionBranch  = data.promotionBranch  || '';
            this.totalComponents  = data.totalComponents  || 0;
            this.validatedBy      = data.validatedBy      || '';
            this.validatedAt      = this.formatDate(data.validatedAt);
            this.canDeploy        = data.canDeploy        || false;
            this.isDeployed       = data.status           === 'Deployed';
            this.userStoryId      = data.userStoryId      || '';
            this.promotionLoaded  = true;
        } catch (e) {
            this.errorMessage = this.getError(e);
        } finally {
            this.isLoading = false;
        }
    }

    // ══════════════════════════════════════════════════════════
    // GETTERS
    // ══════════════════════════════════════════════════════════
    get statusBadgeClass() {
        const base = 'slds-badge ';
        if (this.promotionStatus === 'Validated')         return base + 'slds-badge_lightest';
        if (this.promotionStatus === 'Deployed')          return base;
        if (this.promotionStatus === 'Validation Failed') return base;
        if (this.promotionStatus === 'Deploy Failed')     return base;
        return base + 'slds-badge_lightest';
    }

    // ══════════════════════════════════════════════════════════
    // DEPLOY HANDLER
    // ══════════════════════════════════════════════════════════
    async handleDeploy() {
        this.isDeploying   = true;
        this.errorMessage  = '';
        this.deployStatusLabel = '🔀 Creating promotion branch from feature branch...';

        try {
            const promoBranch = await createPromotionBranch({
                promotionId : this.recordId,
                userStoryId : this.userStoryId
            });

            this.promotionBranch   = promoBranch;
            this.promotionStatus   = 'Deployed';
            this.isDeployed        = true;
            this.canDeploy         = false;
            this.isDeploying       = false;

        } catch (e) {
            this.errorMessage  = this.getError(e);
            this.isDeploying   = false;
            // Reload to get updated status
            await this.loadPromotion();
        }
    }

    // ══════════════════════════════════════════════════════════
    // UTILITIES
    // ══════════════════════════════════════════════════════════
    formatDate(dateStr) {
        if (!dateStr) return '';
        try {
            const d = new Date(dateStr);
            return d.toLocaleDateString('en-GB', {
                day: '2-digit', month: 'short', year: 'numeric',
                hour: '2-digit', minute: '2-digit'
            });
        } catch (e) { return dateStr; }
    }

    getError(e) { return e?.body?.message || e?.message || JSON.stringify(e); }
}