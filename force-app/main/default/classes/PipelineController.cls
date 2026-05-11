// PipelineController.cls

public with sharing class PipelineController {
    
   
    @AuraEnabled(cacheable=true)
    public static List<Environment__c> getEnvironments() {
        return [
            SELECT Id, Name, Org_Name__c, Org_Type__c, Connection_Status__c
            FROM Environment__c
            WHERE Connection_Status__c = 'Connected'
            ORDER BY Org_Name__c
        ];
    }
    
    
    @AuraEnabled
    public static Pipeline__c savePipeline(
        String name,
        Id sourceOrgId,
        Id targetOrgId,
        String sourceBranch,
        String targetBranch,
        String jiraId,
        String status
    ) {
        Pipeline__c pipeline = new Pipeline__c(
            Name             = name,
            Source_Org__c    = sourceOrgId,
            Target_Org__c    = targetOrgId,
            Source_Branch__c = sourceBranch,
            Target_Branch__c = targetBranch,
            Jira_Id__c       = jiraId,
            Status__c        = status
        );
        insert pipeline;
        return pipeline;
    }
    
    
    @AuraEnabled(cacheable=true)
    public static Pipeline__c getPipelineDetail(Id pipelineId) {
        return [
            SELECT Id, Name, Status__c,
                   Source_Org__c, Source_Org__r.Org_Name__c,
                   Source_Org__r.Org_Type__c,
                   Source_Branch__c,
                   Target_Org__c, Target_Org__r.Org_Name__c,
                   Target_Org__r.Org_Type__c,
                   Target_Branch__c,
                   Jira_Id__c
            FROM Pipeline__c
            WHERE Id = :pipelineId
            LIMIT 1
        ];
    }
}