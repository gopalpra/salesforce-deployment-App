public without sharing class DeploymentToolCtrl {

    // ═══════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════
    private static final String  GITHUB_API_BASE = 'https://api.github.com';
    private static final String  API_VERSION     = '64.0';
    private static final Integer TIMEOUT_MS      = 120000;
    private static final Integer BATCH_SIZE      = 10;

    private static final Map<String, String> METADATA_FIELD_MAP = new Map<String, String>{
        'ApexClass'                => 'Name',
        'ApexTrigger'              => 'Name',
        'ApexComponent'            => 'Name',
        'ApexPage'                 => 'Name',
        'LightningComponentBundle' => 'DeveloperName',
        'AuraDefinitionBundle'     => 'DeveloperName',
        'CustomObject'             => 'DeveloperName',
        'FlowDefinition'           => 'DeveloperName',
        'ValidationRule'           => 'ValidationName',
        'CustomField'              => 'DeveloperName',
        'PermissionSet'            => 'Name',
        'CustomLabel'              => 'Name',
        'StaticResource'           => 'Name',
        'EmailTemplate'            => 'Name',
        'GlobalValueSet'           => 'DeveloperName',
        'CustomMetadataType'       => 'DeveloperName',
        'FlexiPage'                => 'DeveloperName'
    };

    private static final Map<String, String> LABEL_FIELD_MAP = new Map<String, String>{
        'ApexClass'                => 'Name',
        'ApexTrigger'              => 'Name',
        'ApexPage'                 => 'MasterLabel',
        'LightningComponentBundle' => 'MasterLabel',
        'AuraDefinitionBundle'     => 'MasterLabel',
        'CustomObject'             => 'DeveloperName',
        'FlowDefinition'           => 'MasterLabel',
        'PermissionSet'            => 'Label',
        'StaticResource'           => 'Name',
        'EmailTemplate'            => 'Name',
        'GlobalValueSet'           => 'MasterLabel',
        'FlexiPage'                => 'MasterLabel',
        'CustomLabel'              => 'Name',
        'CustomField'              => 'DeveloperName',
        'ValidationRule'           => 'Description'
    };

    private static final Map<String, String> FOLDER_TYPE_MAP = new Map<String, String>{
        'classes'         => 'ApexClass',
        'triggers'        => 'ApexTrigger',
        'lwc'             => 'LWC',
        'aura'            => 'Aura',
        'flows'           => 'Flow',
        'objects'         => 'CustomObject',
        'pages'           => 'VF Page',
        'permissionsets'  => 'PermissionSet',
        'labels'          => 'CustomLabel',
        'staticresources' => 'StaticResource',
        'emailtemplates'  => 'EmailTemplate',
        'globalValueSets' => 'GlobalValueSet',
        'flexipages'      => 'FlexiPage',
        'layouts'         => 'Layout',
        'profiles'        => 'Profile',
        'workflows'       => 'Workflow',
        'reports'         => 'Report',
        'dashboards'      => 'Dashboard',
        'customMetadata'  => 'CustomMetadataType'
    };

    private static final Set<String> DEPLOYABLE_TYPES = new Set<String>{
        'ApexClass', 'ApexTrigger', 'ApexPage', 'ApexComponent',
        'LightningComponentBundle', 'AuraDefinitionBundle',
        'CustomObject', 'CustomField', 'ValidationRule',
        'Flow', 'FlowDefinition',
        'PermissionSet', 'Profile',
        'CustomLabel', 'CustomLabels',
        'StaticResource', 'EmailTemplate',
        'GlobalValueSet', 'FlexiPage',
        'Layout', 'Workflow',
        'CustomMetadataType'
    };

    private static final Set<String> VALID_METADATA_TYPES = new Set<String>{
        'ApexClass', 'ApexTrigger', 'ApexPage', 'ApexComponent',
        'LightningComponentBundle', 'AuraDefinitionBundle',
        'CustomObject', 'CustomField', 'ValidationRule',
        'Flow', 'FlowDefinition',
        'PermissionSet', 'Profile',
        'CustomLabel', 'StaticResource', 'EmailTemplate',
        'GlobalValueSet', 'FlexiPage',
        'Layout', 'Workflow',
        'CustomMetadataType'
    };

    private static final Set<String> AUDIT_SUPPORTED = new Set<String>{
        'ApexClass', 'ApexTrigger', 'ApexPage', 'ApexComponent',
        'LightningComponentBundle', 'AuraDefinitionBundle',
        'FlowDefinition', 'PermissionSet', 'StaticResource',
        'EmailTemplate', 'GlobalValueSet', 'CustomObject'
    };

    // ═══════════════════════════════════════════════════════════
    // DYNAMIC GITHUB CONNECTION — Fallback: last modified connected
    // ═══════════════════════════════════════════════════════════
    private static GitHub_Connection__c getActiveGitHubConnection() {
        List<GitHub_Connection__c> conns = [
            SELECT Id, Repo_Owner__c, Repo_Name__c, Access_Token__c
            FROM GitHub_Connection__c
            WHERE Status__c = 'Connected'
            ORDER BY LastModifiedDate DESC
            LIMIT 1
        ];
        if (conns.isEmpty()) {
            throw createAuraException(
                'No active GitHub connection found. Please connect a GitHub repository first from the GitHub Manager.'
            );
        }
        return conns[0];
    }

    // ═══════════════════════════════════════════════════════════
    // Get GitHub Connection from User Story
    // ═══════════════════════════════════════════════════════════
    private static GitHub_Connection__c getConnectionFromUserStory(String userStoryId) {
        if (String.isBlank(userStoryId)) {
            return getActiveGitHubConnection();
        }

        List<User_Story_Name__c> stories = [
            SELECT GitHub_Connection__c,
                   GitHub_Connection__r.Repo_Owner__c,
                   GitHub_Connection__r.Repo_Name__c,
                   GitHub_Connection__r.Access_Token__c,
                   GitHub_Connection__r.Status__c
            FROM User_Story_Name__c
            WHERE Id = :userStoryId
            LIMIT 1
        ];

        if (stories.isEmpty()) {
            throw createAuraException('User Story not found.');
        }

        if (stories[0].GitHub_Connection__c == null) {
            throw createAuraException(
                '❌ No GitHub Connection assigned to this User Story. ' +
                'Please edit the User Story and select a GitHub Connection before deploying.'
            );
        }

        if (stories[0].GitHub_Connection__r.Status__c != 'Connected') {
            throw createAuraException(
                '❌ The GitHub Connection assigned to this User Story is not active. ' +
                'Please go to GitHub Manager and reconnect it.'
            );
        }

        return stories[0].GitHub_Connection__r;
    }

    // ═══════════════════════════════════════════════════════════
    // Get Default Branch Dynamically (main / master / custom)
    // ═══════════════════════════════════════════════════════════
    private static String getDefaultBranch(String accessToken, String owner, String repo) {
        try {
            HttpResponse res = githubGet(accessToken, repoPath(owner, repo, ''));
            if (res.getStatusCode() == 200) {
                Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                String branch = String.valueOf(data.get('default_branch'));
                return (String.isBlank(branch) || branch == 'null') ? 'main' : branch;
            }
        } catch (Exception e) {}
        return 'main'; // fallback
    }

    // ═══════════════════════════════════════════════════════════
    // GITHUB HTTP HELPERS — dynamic token
    // ═══════════════════════════════════════════════════════════
    private static HttpResponse githubGet(String accessToken, String path) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(GITHUB_API_BASE + path);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setHeader('Accept', 'application/vnd.github+json');
        req.setHeader('X-GitHub-Api-Version', '2022-11-28');
        req.setTimeout(TIMEOUT_MS);
        return new Http().send(req);
    }

    private static HttpResponse githubPost(String accessToken, String method, String path, Object bodyObj) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(GITHUB_API_BASE + path);
        req.setMethod(method);
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setHeader('Accept', 'application/vnd.github+json');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('X-GitHub-Api-Version', '2022-11-28');
        req.setBody(JSON.serialize(bodyObj));
        req.setTimeout(TIMEOUT_MS);
        return new Http().send(req);
    }

    private static String repoPath(String owner, String repo, String suffix) {
        return '/repos/' + owner + '/' + repo + suffix;
    }

    private static void checkGitHubRateLimit(HttpResponse res, String context) {
        if (res.getStatusCode() == 429)
            throw createAuraException(context + ': GitHub rate limit hit. Please wait and retry.');
    }

    // ═══════════════════════════════════════════════════════════
    // Fetch org details from User Story
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled(cacheable=false)
    public static Map<String, String> getOrgDetailsFromUserStory(String userStoryId) {
        try {
            User_Story_Name__c us = [
                SELECT Source_Org__c,        Target_Org__c,
                       Source_Org__r.Name,   Target_Org__r.Name,
                       Source_Org__r.Org_Name__c,   Target_Org__r.Org_Name__c,
                       Source_Org__r.Org_Type__c,   Target_Org__r.Org_Type__c,
                       Source_Org__r.Refresh_Token__c, Target_Org__r.Refresh_Token__c,
                       Source_Org__r.Connection_Status__c, Target_Org__r.Connection_Status__c
                FROM User_Story_Name__c
                WHERE Id = :userStoryId
                LIMIT 1
            ];

            if (us.Source_Org__c == null)
                throw createAuraException('Source Org is not selected on the User Story.');
            if (us.Target_Org__c == null)
                throw createAuraException('Target Org is not selected on the User Story.');
            if (String.isBlank(us.Source_Org__r.Refresh_Token__c))
                throw createAuraException('Source Org "' + us.Source_Org__r.Org_Name__c + '" is not connected. Please go to the Environments app and click "Connect Org".');
            if (String.isBlank(us.Target_Org__r.Refresh_Token__c))
                throw createAuraException('Target Org "' + us.Target_Org__r.Org_Name__c + '" is not connected. Please go to the Environments app and click "Connect Org".');

            return new Map<String, String>{
                'sourceOrgId'            => us.Source_Org__c,
                'targetOrgId'            => us.Target_Org__c,
                'sourceOrgName'          => us.Source_Org__r.Org_Name__c,
                'targetOrgName'          => us.Target_Org__r.Org_Name__c,
                'sourceOrgType'          => us.Source_Org__r.Org_Type__c,
                'targetOrgType'          => us.Target_Org__r.Org_Type__c,
                'sourceRefreshToken'     => us.Source_Org__r.Refresh_Token__c,
                'targetRefreshToken'     => us.Target_Org__r.Refresh_Token__c,
                'sourceConnectionStatus' => us.Source_Org__r.Connection_Status__c,
                'targetConnectionStatus' => us.Target_Org__r.Connection_Status__c
            };
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('getOrgDetailsFromUserStory: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Refresh Access Token
    // ═══════════════════════════════════════════════════════════
   @AuraEnabled
public static Map<String, String> refreshAccessToken(String refreshToken, String orgType, String orgName) {
    try {
      List<OAuth_Config__mdt> configs = [
    SELECT Client_Id__c, Client_Secret__c, Callback_Url__c
    FROM OAuth_Config__mdt
    WHERE App_Type__c = 'Salesforce'
    AND DeveloperName = :orgName.capitalize()
    LIMIT 1
];

if(configs.isEmpty()) {
    configs = [
        SELECT Client_Id__c, Client_Secret__c, Callback_Url__c
        FROM OAuth_Config__mdt
        WHERE DeveloperName = 'Default'
        LIMIT 1
    ];
}

OAuth_Config__mdt config = configs[0];
        Boolean isSandbox     = (orgType != null && orgType.toLowerCase() == 'sandbox');
        String  orgTypeLabel  = isSandbox ? 'Sandbox' : 'Production';
        String  tokenEndpoint = isSandbox
            ? 'https://test.salesforce.com/services/oauth2/token'
            : 'https://login.salesforce.com/services/oauth2/token';

        HttpRequest req = new HttpRequest();
        req.setEndpoint(tokenEndpoint);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
        req.setBody(
            'grant_type=refresh_token'
            + '&client_id='     + EncodingUtil.urlEncode(config.Client_Id__c,     'UTF-8')
            + '&client_secret=' + EncodingUtil.urlEncode(config.Client_Secret__c, 'UTF-8')
            + '&refresh_token=' + EncodingUtil.urlEncode(refreshToken,            'UTF-8')
        );
        req.setTimeout(TIMEOUT_MS);

        HttpResponse res      = new Http().send(req);
        String       respBody = res.getBody();

        if (res.getStatusCode() != 200) {
            String friendlyMsg;
            if (respBody.contains('invalid_grant') || respBody.contains('expired')) {
                friendlyMsg = '⚠️ ' + orgTypeLabel + ' org refresh token has either expired or been revoked.\n'
                    + 'Please go to the Environments app and click the "Connect Org" button for this org to reconnect it.\n'
                    + 'This will generate a fresh token.';
            } else if (respBody.contains('invalid_client')) {
                friendlyMsg = '⚠️ Connected App credentials are incorrect (' + orgTypeLabel + ').\n'
                    + 'Please check the Client_Id and Client_Secret in OAuth_Config__mdt.';
            } else if (respBody.contains('inactive_user') || respBody.contains('inactive_org')) {
                friendlyMsg = '⚠️ ' + orgTypeLabel + ' org or user is inactive.\n'
                    + 'Please contact the Salesforce admin and check the org/user status.';
            } else {
                friendlyMsg = 'Token refresh failed (' + res.getStatusCode() + ') for ' + orgTypeLabel + ' org: ' + respBody;
            }
            throw createAuraException(friendlyMsg);
        }

        Map<String, Object> parsed      = (Map<String, Object>) JSON.deserializeUntyped(respBody);
        String              accessToken = String.valueOf(parsed.get('access_token'));
        String              instanceUrl = String.valueOf(parsed.get('instance_url'));

        if (String.isBlank(accessToken) || accessToken == 'null')
            throw createAuraException('⚠️ ' + orgTypeLabel + ' org access token is blank.\nPlease go to the Environments app and connect the org again.');
        if (String.isBlank(instanceUrl) || instanceUrl == 'null')
            throw createAuraException('⚠️ ' + orgTypeLabel + ' org instance URL is blank.\nGo to the Environments app and reconnect the org again.');

        return new Map<String, String>{
            'accessToken' => accessToken,
            'instanceUrl' => instanceUrl
        };
    } catch (AuraHandledException e) {
        throw e;
    } catch (Exception e) {
        throw createAuraException('refreshAccessToken: ' + e.getMessage());
    }
}

    // ═══════════════════════════════════════════════════════════
    // Fetch components from dynamic org
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled(cacheable=false)
    public static List<Map<String, String>> getComponentsDynamic(
            String metadataType, String accessToken, String instanceUrl) {
        try {
            if (metadataType == 'CustomMetadataType') {
                HttpResponse res = dynamicGet(instanceUrl, accessToken,
                    '/services/data/v' + API_VERSION +
                    '/tooling/query?q=' + EncodingUtil.urlEncode(
                        'SELECT Id, DeveloperName, QualifiedApiName, Label FROM EntityDefinition WHERE QualifiedApiName LIKE \'%__mdt\'', 'UTF-8'));
                if (res.getStatusCode() != 200)
                    throw createAuraException('Fetch error (' + res.getStatusCode() + '): ' + res.getBody());
                Map<String, Object>       parsed  = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                List<Object>              records = (List<Object>) parsed.get('records');
                List<Map<String, String>> result  = new List<Map<String, String>>();
                if (records == null || records.isEmpty()) return result;
                for (Object rec : records) {
                    Map<String, Object> r    = (Map<String, Object>) rec;
                    String              id   = String.valueOf(r.get('Id'));
                    String              name = String.valueOf(r.get('QualifiedApiName'));
                    if (String.isNotBlank(id) && String.isNotBlank(name) && name != 'null')
                        result.add(new Map<String, String>{ 'id' => id, 'name' => name, 'label' => r.get('Label') != null ? String.valueOf(r.get('Label')) : name });
                }
                return result;
            }

            if (metadataType == 'CustomLabel') {
                HttpResponse clRes = dynamicGet(instanceUrl, accessToken,
                    '/services/data/v' + API_VERSION +
                    '/tooling/query?q=' + EncodingUtil.urlEncode('SELECT Id, Name, MasterLabel FROM CustomLabel', 'UTF-8'));
                if (clRes.getStatusCode() != 200)
                    throw createAuraException('CustomLabel fetch error: ' + clRes.getBody());
                Map<String, Object>       clParsed  = (Map<String, Object>) JSON.deserializeUntyped(clRes.getBody());
                List<Object>              clRecords = (List<Object>) clParsed.get('records');
                List<Map<String, String>> clResult  = new List<Map<String, String>>();
                if (clRecords != null) {
                    for (Object rec : clRecords) {
                        Map<String, Object> r    = (Map<String, Object>) rec;
                        String              id   = String.valueOf(r.get('Id'));
                        String              name = String.valueOf(r.get('Name'));
                        String              lbl  = r.get('MasterLabel') != null ? String.valueOf(r.get('MasterLabel')) : name;
                        if (String.isNotBlank(id) && String.isNotBlank(name) && name != 'null')
                            clResult.add(new Map<String, String>{ 'id' => id, 'name' => name, 'label' => lbl });
                    }
                }
                return clResult;
            }

            String nameField    = METADATA_FIELD_MAP.containsKey(metadataType) ? METADATA_FIELD_MAP.get(metadataType) : 'Name';
            String labelField   = LABEL_FIELD_MAP.containsKey(metadataType)    ? LABEL_FIELD_MAP.get(metadataType)   : '';
            String selectFields = 'Id,' + nameField;
            if (String.isNotBlank(labelField) && labelField != nameField) selectFields += ',' + labelField;
            if (metadataType == 'ValidationRule' || metadataType == 'CustomField') selectFields += ',EntityDefinition.QualifiedApiName';
            if (AUDIT_SUPPORTED.contains(metadataType)) selectFields += ',CreatedDate,LastModifiedDate,CreatedBy.Name,LastModifiedBy.Name';

            HttpResponse res = dynamicGet(instanceUrl, accessToken,
                '/services/data/v' + API_VERSION + '/tooling/query?q=' +
                EncodingUtil.urlEncode('SELECT ' + selectFields + ' FROM ' + metadataType, 'UTF-8'));
            if (res.getStatusCode() != 200)
                throw createAuraException('Fetch error (' + res.getStatusCode() + '): ' + res.getBody());

            Map<String, Object>       parsed  = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object>              records = (List<Object>) parsed.get('records');
            List<Map<String, String>> result  = new List<Map<String, String>>();
            if (records == null || records.isEmpty()) return result;

            for (Object rec : records) {
                Map<String, Object> r    = (Map<String, Object>) rec;
                String              id   = String.valueOf(r.get('Id'));
                String              name = resolveComponentName(r, metadataType, nameField);
                if (String.isNotBlank(id) && String.isNotBlank(name) && name != 'null') {
                    Map<String, String> entry = new Map<String, String>{ 'id' => id, 'name' => name };
                    String labelValue = (String.isNotBlank(labelField) && r.get(labelField) != null) ? String.valueOf(r.get(labelField)) : '';
                    if (labelValue == 'null') labelValue = '';
                    entry.put('label', String.isBlank(labelValue) ? name : labelValue);
                    if (AUDIT_SUPPORTED.contains(metadataType)) entry = addAuditFields(entry, r);
                    result.add(entry);
                }
            }
            return result;

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('getComponentsDynamic Error: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Dynamic SOAP Retrieve
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String startRetrieveDynamic(
            List<String> componentNames, String metadataType,
            String accessToken, String instanceUrl) {
        try {
            String retrieveType = metadataType == 'FlowDefinition'     ? 'Flow'         :
                                  metadataType == 'CustomMetadataType' ? 'CustomObject' :
                                  metadataType;

            Set<String> membersToRetrieve = new Set<String>(componentNames);
            Set<String> parentObjects     = new Set<String>();
            for (String name : componentNames) {
                if (name.contains('.'))     parentObjects.add(name.split('\\.')[0]);
                if (name.endsWith('__mdt')) parentObjects.add(name);
            }

            String membersXml = '';
            for (String m : membersToRetrieve) membersXml += '<met:members>' + escapeXml(m) + '</met:members>';

            String extraTypesXml = '';
            if (!parentObjects.isEmpty()) {
                String objMembers = '';
                for (String obj : parentObjects) objMembers += '<met:members>' + escapeXml(obj) + '</met:members>';
                extraTypesXml = '<met:types>' + objMembers + '<met:name>CustomObject</met:name></met:types>';
            }

            String soap =
                '<?xml version="1.0" encoding="utf-8"?>' +
                '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:met="http://soap.sforce.com/2006/04/metadata">' +
                '<soapenv:Header><met:SessionHeader><met:sessionId>' + accessToken + '</met:sessionId></met:SessionHeader></soapenv:Header>' +
                '<soapenv:Body><met:retrieve><met:retrieveRequest>' +
                '<met:apiVersion>' + API_VERSION + '</met:apiVersion>' +
                '<met:singlePackage>true</met:singlePackage>' +
                '<met:unpackaged>' +
                '<met:types>' + membersXml + '<met:name>' + retrieveType + '</met:name></met:types>' +
                extraTypesXml +
                '<met:version>' + API_VERSION + '</met:version>' +
                '</met:unpackaged></met:retrieveRequest></met:retrieve></soapenv:Body></soapenv:Envelope>';

            HttpRequest req = new HttpRequest();
            req.setEndpoint(instanceUrl + '/services/Soap/m/' + API_VERSION);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
            req.setHeader('SOAPAction', '""');
            req.setBody(soap);
            req.setTimeout(TIMEOUT_MS);

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                String fault = extractTagValue(res.getBody(), 'faultstring');
                throw createAuraException('Retrieve Failed: ' + (fault != null ? fault : res.getBody()));
            }
            return extractTagValue(res.getBody(), 'id');
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('startRetrieveDynamic: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Check Retrieve Status
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static Map<String, Object> checkRetrieveStatusDynamic(
            String jobId, String accessToken, String instanceUrl) {
        try {
            String soap =
                '<?xml version="1.0" encoding="utf-8"?>' +
                '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:met="http://soap.sforce.com/2006/04/metadata">' +
                '<soapenv:Header><met:SessionHeader><met:sessionId>' + accessToken + '</met:sessionId></met:SessionHeader></soapenv:Header>' +
                '<soapenv:Body><met:checkRetrieveStatus>' +
                '<met:asyncProcessId>' + jobId + '</met:asyncProcessId>' +
                '<met:includeZip>true</met:includeZip>' +
                '</met:checkRetrieveStatus></soapenv:Body></soapenv:Envelope>';

            HttpRequest req = new HttpRequest();
            req.setEndpoint(instanceUrl + '/services/Soap/m/' + API_VERSION);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
            req.setHeader('SOAPAction', '""');
            req.setBody(soap);
            req.setTimeout(TIMEOUT_MS);

            HttpResponse res  = new Http().send(req);
            String       body = res.getBody();
            if (res.getStatusCode() != 200) {
                String fault = extractTagValue(body, 'faultstring');
                throw createAuraException('checkRetrieveStatus Error: ' + (fault != null ? fault : body));
            }

            String status = extractTagValue(body, 'status');
            if (status == 'Succeeded') {
                String zipFile = extractTagValue(body, 'zipFile');
                if (String.isBlank(zipFile)) throw createAuraException('Zip is empty!');
                if (zipFile.length() > 10000000)
                    throw createAuraException('ZIP too large (' + (zipFile.length()/1000000) + 'MB). Please select fewer components.');
                return new Map<String, Object>{ 'status' => 'Succeeded', 'zip' => zipFile };
            }
            if (status == 'Failed') {
                String errMsg = extractTagValue(body, 'message');
                return new Map<String, Object>{ 'status' => 'Failed', 'message' => String.isNotBlank(errMsg) ? errMsg : 'Unknown retrieve error' };
            }
            return new Map<String, Object>{ 'status' => String.isNotBlank(status) ? status : 'InProgress' };
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('checkRetrieveStatusDynamic: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Component Dependencies
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static List<Map<String, String>> getComponentDependencies(
            List<String> componentIds, String accessToken, String instanceUrl) {
        if (componentIds == null || componentIds.isEmpty()) return new List<Map<String, String>>();
        try {
            List<String> quotedIds = new List<String>();
            for (String cid : componentIds) quotedIds.add('\'' + cid + '\'');
            String query =
                'SELECT MetadataComponentName, MetadataComponentType, RefMetadataComponentName, RefMetadataComponentType ' +
                'FROM MetadataComponentDependency WHERE MetadataComponentId IN (' + String.join(quotedIds, ',') + ')';

            HttpResponse res = dynamicGet(instanceUrl, accessToken,
                '/services/data/v' + API_VERSION + '/tooling/query?q=' + EncodingUtil.urlEncode(query, 'UTF-8'));
            if (res.getStatusCode() != 200)
                throw createAuraException('Dependency fetch failed: ' + res.getBody());

            Map<String, Object>       parsed       = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object>              records      = (List<Object>) parsed.get('records');
            List<Map<String, String>> dependencies = new List<Map<String, String>>();
            if (records == null || records.isEmpty()) return dependencies;

            Set<String> uniqueKeys = new Set<String>();
            for (Object rec : records) {
                Map<String, Object> r       = (Map<String, Object>) rec;
                String              refName = String.valueOf(r.get('RefMetadataComponentName'));
                String              refType = String.valueOf(r.get('RefMetadataComponentType'));
                String              srcName = String.valueOf(r.get('MetadataComponentName'));
                if (String.isBlank(refName) || String.isBlank(refType) || refName == 'null' || refType == 'null') continue;
                if (refType == 'StandardEntity') {
                    if (!refName.contains('__c') && !refName.contains('__mdt') && !refName.contains('__e') && !refName.contains('__b')) continue;
                    refType = refName.contains('__mdt') ? 'CustomMetadataType' : 'CustomObject';
                }
                if (!DEPLOYABLE_TYPES.contains(refType)) continue;
                if (refType == 'CustomField' && !refName.contains('__')) continue;
                String key = refType + '#' + refName;
                if (!uniqueKeys.contains(key)) {
                    uniqueKeys.add(key);
                    dependencies.add(new Map<String, String>{ 'metadataType' => refType, 'name' => refName, 'requiredBy' => srcName });
                }
            }
            return dependencies;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('getComponentDependencies Error: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // GitHub: Get Main Branch SHA (dynamic default branch)
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String getMainBranchSha(String userStoryId) {
        try {
            GitHub_Connection__c conn          = getConnectionFromUserStory(userStoryId);
            String               defaultBranch = getDefaultBranch(conn.Access_Token__c, conn.Repo_Owner__c, conn.Repo_Name__c);

            HttpResponse res = githubGet(conn.Access_Token__c,
                repoPath(conn.Repo_Owner__c, conn.Repo_Name__c, '/git/ref/heads/' + defaultBranch));
            checkGitHubRateLimit(res, 'getMainBranchSha');
            if (res.getStatusCode() != 200)
                throw createAuraException('GitHub SHA fetch failed (' + res.getStatusCode() + '): ' + res.getBody());

            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String sha = String.valueOf(((Map<String, Object>) parsed.get('object')).get('sha'));
            if (String.isBlank(sha) || sha == 'null') throw createAuraException('SHA value is empty.');
            return sha;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('getMainBranchSha: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // GitHub: Create Feature Branch (dynamic default branch)
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String createFeatureBranch(String branchName, String sha, String userStoryId) {
        try {
            GitHub_Connection__c conn = getConnectionFromUserStory(userStoryId);
            HttpResponse res = githubPost(conn.Access_Token__c, 'POST',
                repoPath(conn.Repo_Owner__c, conn.Repo_Name__c, '/git/refs'),
                new Map<String, String>{ 'ref' => 'refs/heads/' + branchName, 'sha' => sha });
            checkGitHubRateLimit(res, 'createFeatureBranch');
            if (res.getStatusCode() != 201 && res.getStatusCode() != 422)
                throw createAuraException('Branch create failed (' + res.getStatusCode() + '): ' + res.getBody());
            return branchName;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('createFeatureBranch: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // GitHub: Push Multiple Files (dynamic default branch)
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static Boolean pushMultipleFilesToGitHub(String branchName, String commitMessage, List<Map<String, String>> files, String userStoryId) {
        try {
            GitHub_Connection__c conn  = getConnectionFromUserStory(userStoryId);
            String               owner = conn.Repo_Owner__c;
            String               repo  = conn.Repo_Name__c;
            String               token = conn.Access_Token__c;

            HttpResponse refRes = githubGet(token, repoPath(owner, repo, '/git/ref/heads/' + branchName));
            checkGitHubRateLimit(refRes, 'Get Ref');
            String latestCommitSha = String.valueOf(
                ((Map<String, Object>)((Map<String, Object>) JSON.deserializeUntyped(refRes.getBody())).get('object')).get('sha'));

            HttpResponse commitRes = githubGet(token, repoPath(owner, repo, '/git/commits/' + latestCommitSha));
            checkGitHubRateLimit(commitRes, 'Get Commit');
            String baseTreeSha = String.valueOf(
                ((Map<String, Object>)((Map<String, Object>) JSON.deserializeUntyped(commitRes.getBody())).get('tree')).get('sha'));

            // ── Batch blob creation ─────────────────────────
            List<Map<String, Object>>       treeNodes = new List<Map<String, Object>>();
            List<List<Map<String, String>>> batches   = new List<List<Map<String, String>>>();
            List<Map<String, String>>       current   = new List<Map<String, String>>();

            for (Map<String, String> file : files) {
                current.add(file);
                if (current.size() == BATCH_SIZE) { batches.add(current); current = new List<Map<String, String>>(); }
            }
            if (!current.isEmpty()) batches.add(current);

            for (List<Map<String, String>> batch : batches) {
                for (Map<String, String> file : batch) {
                    HttpResponse        blobRes    = githubPost(token, 'POST', repoPath(owner, repo, '/git/blobs'),
                        new Map<String, Object>{ 'content' => file.get('base64Content'), 'encoding' => 'base64' });
                    Map<String, Object> blobParsed = (Map<String, Object>) JSON.deserializeUntyped(blobRes.getBody());
                    treeNodes.add(new Map<String, Object>{
                        'path' => file.get('filePath'), 'mode' => '100644',
                        'type' => 'blob', 'sha'  => String.valueOf(blobParsed.get('sha'))
                    });
                }
            }

            String newTreeSha = String.valueOf(((Map<String, Object>) JSON.deserializeUntyped(
                githubPost(token, 'POST', repoPath(owner, repo, '/git/trees'),
                    new Map<String, Object>{ 'base_tree' => baseTreeSha, 'tree' => treeNodes }).getBody())).get('sha'));

            String newCommitSha = String.valueOf(((Map<String, Object>) JSON.deserializeUntyped(
                githubPost(token, 'POST', repoPath(owner, repo, '/git/commits'),
                    new Map<String, Object>{ 'message' => commitMessage, 'tree' => newTreeSha,
                        'parents' => new List<String>{ latestCommitSha } }).getBody())).get('sha'));

            HttpResponse updateRefRes = githubPost(token, 'PATCH',
                repoPath(owner, repo, '/git/refs/heads/' + branchName),
                new Map<String, Object>{ 'sha' => newCommitSha });
            checkGitHubRateLimit(updateRefRes, 'Update Ref');
            return true;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('pushMultipleFilesToGitHub: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // GitHub: Create Pull Request (dynamic base branch)
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String createPullRequest(
            String branchName, String title, String prBody, String userStoryId) {
        try {
            GitHub_Connection__c conn          = getConnectionFromUserStory(userStoryId);
            String               defaultBranch = getDefaultBranch(conn.Access_Token__c, conn.Repo_Owner__c, conn.Repo_Name__c);
            String               deployedBy    = UserInfo.getName();

            if (String.isNotBlank(userStoryId)) {
                try {
                    User_Story_Name__c us = [
                        SELECT Name, Jira_ID__c, Priority__c,
                               Release_Version__c, Summary__c,
                               Source_Org__r.Org_Name__c,
                               Target_Org__r.Org_Name__c
                        FROM User_Story_Name__c
                        WHERE Id = :userStoryId
                        LIMIT 1
                    ];
                    prBody =
                        '👤 Deployed By  : ' + deployedBy + '\n' +
                        '📋 User Story   : ' + us.Name    + '\n' +
                        '📝 Summary      : ' + (String.isNotBlank(us.Summary__c)         ? us.Summary__c         : 'N/A') + '\n' +
                        '🎯 Jira ID      : ' + (String.isNotBlank(us.Jira_ID__c)         ? us.Jira_ID__c         : 'N/A') + '\n' +
                        '🏷️ Priority     : ' + (String.isNotBlank(us.Priority__c)        ? us.Priority__c        : 'N/A') + '\n' +
                        '📦 Release      : ' + (String.isNotBlank(us.Release_Version__c) ? us.Release_Version__c : 'N/A') + '\n' +
                        '🔀 Source Org   : ' + us.Source_Org__r.Org_Name__c + '\n' +
                        '🎯 Target Org   : ' + us.Target_Org__r.Org_Name__c + '\n' +
                        '🌿 Branch       : ' + branchName;
                } catch (Exception ex) {
                    prBody = '👤 Deployed By : ' + deployedBy + '\n🌿 Branch : ' + branchName;
                }
            } else {
                prBody = '👤 Deployed By : ' + deployedBy + '\n'
                    + (String.isBlank(prBody) ? 'Auto-generated PR\n🌿 Branch: ' + branchName : prBody);
            }

            HttpResponse res = githubPost(conn.Access_Token__c, 'POST',
                repoPath(conn.Repo_Owner__c, conn.Repo_Name__c, '/pulls'),
                new Map<String, Object>{
                    'title' => title,
                    'head'  => branchName,
                    'base'  => defaultBranch,
                    'body'  => prBody
                });
            checkGitHubRateLimit(res, 'createPullRequest');
            if (res.getStatusCode() != 201)
                throw createAuraException('PR creation failed (' + res.getStatusCode() + '): ' + res.getBody());
            String prNumber = String.valueOf(((Map<String, Object>) JSON.deserializeUntyped(res.getBody())).get('number'));
            if (String.isBlank(prNumber) || prNumber == 'null') throw createAuraException('PR number blank.');
            return prNumber;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('createPullRequest: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // GitHub: Merge Pull Request
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static Boolean mergePullRequest(String prNumber, String userStoryId) {
        try {
            GitHub_Connection__c conn = getConnectionFromUserStory(userStoryId);
            HttpResponse res = githubPost(conn.Access_Token__c, 'PUT',
                repoPath(conn.Repo_Owner__c, conn.Repo_Name__c, '/pulls/' + prNumber + '/merge'),
                new Map<String, String>{
                    'commit_title' => 'Auto-merge by Deployment Tool',
                    'merge_method' => 'squash'
                });
            checkGitHubRateLimit(res, 'mergePullRequest');
            if (res.getStatusCode() != 200)
                throw createAuraException('PR merge failed (' + res.getStatusCode() + '): ' + res.getBody());
            return true;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('mergePullRequest: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // ✅ FIXED — GitHub: Get Previous Commits (userStoryId dynamic)
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static List<Map<String, Object>> getPreviousCommits(String userStoryId) {
        try {
            GitHub_Connection__c conn = getConnectionFromUserStory(userStoryId);
            HttpResponse res = githubGet(conn.Access_Token__c,
                repoPath(conn.Repo_Owner__c, conn.Repo_Name__c,
                    '/pulls?state=closed&per_page=20&sort=updated&direction=desc'));
            checkGitHubRateLimit(res, 'getPreviousCommits');
            if (res.getStatusCode() != 200)
                throw createAuraException('PR fetch failed (' + res.getStatusCode() + '): ' + res.getBody());

            List<Object>              pullRequests = (List<Object>) JSON.deserializeUntyped(res.getBody());
            List<Map<String, Object>> result       = new List<Map<String, Object>>();
            for (Object prObj : pullRequests) {
                Map<String, Object> pr = (Map<String, Object>) prObj;
                if (pr.get('merged_at') == null) continue;
                Integer prNum = (Integer) pr.get('number');
                result.add(new Map<String, Object>{
                    'number'   => prNum,
                    'title'    => String.valueOf(pr.get('title')),
                    'mergedAt' => formatGitHubDate(String.valueOf(pr.get('merged_at'))),
                    'files'    => getPrFiles(conn.Access_Token__c, conn.Repo_Owner__c, conn.Repo_Name__c, prNum)
                });
            }
            return result;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('getPreviousCommits: ' + e.getMessage());
        }
    }

    private static List<Map<String, Object>> getPrFiles(String token, String owner, String repo, Integer prNumber) {
        List<Map<String, Object>> files = new List<Map<String, Object>>();
        try {
            HttpResponse res = githubGet(token, repoPath(owner, repo, '/pulls/' + prNumber + '/files?per_page=100'));
            if (res.getStatusCode() != 200) return files;
            for (Object f : (List<Object>) JSON.deserializeUntyped(res.getBody())) {
                Map<String, Object> fileMap  = (Map<String, Object>) f;
                String              filePath = String.valueOf(fileMap.get('filename'));
                if (filePath == null || filePath.endsWith('package.xml')) continue;
                String componentName = extractComponentName(filePath);
                if (String.isNotBlank(componentName))
                    files.add(new Map<String, Object>{
                        'path' => filePath, 'name' => componentName,
                        'metadataType' => extractMetadataType(filePath)
                    });
            }
        } catch (Exception e) {}
        return files;
    }

    // ═══════════════════════════════════════════════════════════
    // ✅ FIXED — Save Deployment Log (userStoryId dynamic)
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String saveDeploymentLog(
            String prNumber, String prTitle, String branchName,
            String deployStatus, List<Map<String, String>> components,
            String userStoryId) {
        try {
            GitHub_Connection__c conn = getConnectionFromUserStory(userStoryId);

            Deployment_Log__c log = new Deployment_Log__c(
                PR_Number__c        = prNumber,
                PR_Title__c         = prTitle,
                Branch_Name__c      = branchName,
                PR_URL__c           = 'https://github.com/' + conn.Repo_Owner__c + '/' + conn.Repo_Name__c + '/pull/' + prNumber,
                Status__c           = String.isNotBlank(deployStatus) ? deployStatus : 'Deployed',
                Merged_At__c        = DateTime.now(),
                Deployed_By__c      = UserInfo.getUserId(),
                Total_Components__c = components.size()
            );
            insert log;

            List<Deployment_Component__c> comps = new List<Deployment_Component__c>();
            for (Map<String, String> comp : components) {
                comps.add(new Deployment_Component__c(
                    Name                  = comp.get('name'),
                    Deployment_Log__c     = log.Id,
                    Metadata_Type__c      = sanitizeMetadataType(comp.get('metadataType')),
                    Component_API_Name__c = comp.get('name'),
                    File_Path__c          = comp.get('filePath'),
                    Operation__c          = 'Deploy'
                ));
            }
            insert comps;
            return log.Id;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('saveDeploymentLog: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // ✅ FIXED — Sync Deployment Status (userStoryId dynamic)
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String syncDeploymentStatus(String logId, String branchName, String userStoryId) {
        try {
            GitHub_Connection__c conn        = getConnectionFromUserStory(userStoryId);
            String               finalStatus = 'Failed';
            HttpResponse         res         = githubGet(conn.Access_Token__c,
                repoPath(conn.Repo_Owner__c, conn.Repo_Name__c,
                    '/actions/runs?branch=' + EncodingUtil.urlEncode(branchName, 'UTF-8') + '&per_page=1'));
            checkGitHubRateLimit(res, 'syncDeploymentStatus');

            if (res.getStatusCode() == 200) {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                List<Object>        runs   = (List<Object>) parsed.get('workflow_runs');
                if (runs != null && !runs.isEmpty()) {
                    Map<String, Object> latestRun  = (Map<String, Object>) runs[0];
                    String              status     = String.valueOf(latestRun.get('status'));
                    String              conclusion = String.valueOf(latestRun.get('conclusion'));
                    if (status == 'completed') {
                        finalStatus = (conclusion == 'success') ? 'Deployed' : 'Failed';
                    } else {
                        return 'In Progress';
                    }
                }
            }
            update new Deployment_Log__c(Id = logId, Status__c = finalStatus);
            return finalStatus;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('syncDeploymentStatus: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Deploy to Target Org
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String startDeployToTargetOrg(String zipBase64, String accessToken, String instanceUrl) {
        try {
            String soap =
                '<?xml version="1.0" encoding="utf-8"?>' +
                '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:met="http://soap.sforce.com/2006/04/metadata">' +
                '<soapenv:Header><met:SessionHeader><met:sessionId>' + accessToken + '</met:sessionId></met:SessionHeader></soapenv:Header>' +
                '<soapenv:Body><met:deploy>' +
                '<met:ZipFile>' + zipBase64 + '</met:ZipFile>' +
                '<met:DeployOptions>' +
                '<met:allowMissingFiles>false</met:allowMissingFiles>' +
                '<met:autoUpdatePackage>false</met:autoUpdatePackage>' +
                '<met:checkOnly>false</met:checkOnly>' +
                '<met:ignoreWarnings>true</met:ignoreWarnings>' +
                '<met:performRetrieve>false</met:performRetrieve>' +
                '<met:purgeOnDelete>false</met:purgeOnDelete>' +
                '<met:rollbackOnError>true</met:rollbackOnError>' +
                '<met:runAllTests>false</met:runAllTests>' +
                '<met:singlePackage>true</met:singlePackage>' +
                '</met:DeployOptions>' +
                '</met:deploy></soapenv:Body></soapenv:Envelope>';

            HttpRequest req = new HttpRequest();
            req.setEndpoint(instanceUrl + '/services/Soap/m/' + API_VERSION);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
            req.setHeader('SOAPAction', '""');
            req.setBody(soap);
            req.setTimeout(TIMEOUT_MS);

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                String fault = extractTagValue(res.getBody(), 'faultstring');
                throw createAuraException('Deploy Failed: ' + (fault != null ? fault : res.getBody()));
            }
            String jobId = extractTagValue(res.getBody(), 'id');
            if (String.isBlank(jobId)) throw createAuraException('Deploy job ID is blank.');
            return jobId;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('startDeployToTargetOrg: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Check Deploy Status
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static Map<String, Object> checkDeployStatus(String jobId, String accessToken, String instanceUrl) {
        try {
            String soap =
                '<?xml version="1.0" encoding="utf-8"?>' +
                '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:met="http://soap.sforce.com/2006/04/metadata">' +
                '<soapenv:Header><met:SessionHeader><met:sessionId>' + accessToken + '</met:sessionId></met:SessionHeader></soapenv:Header>' +
                '<soapenv:Body><met:checkDeployStatus>' +
                '<met:asyncProcessId>' + jobId + '</met:asyncProcessId>' +
                '<met:includeDetails>true</met:includeDetails>' +
                '</met:checkDeployStatus></soapenv:Body></soapenv:Envelope>';

            HttpRequest req = new HttpRequest();
            req.setEndpoint(instanceUrl + '/services/Soap/m/' + API_VERSION);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
            req.setHeader('SOAPAction', '""');
            req.setBody(soap);
            req.setTimeout(TIMEOUT_MS);

            HttpResponse res  = new Http().send(req);
            String       body = res.getBody();
            if (res.getStatusCode() != 200) {
                String fault = extractTagValue(body, 'faultstring');
                throw createAuraException('checkDeployStatus Error: ' + (fault != null ? fault : body));
            }

            String  status   = extractTagValue(body, 'status');
            Boolean done     = status == 'Succeeded' || status == 'Failed' || status == 'Canceled';
            String  errorMsg = '';

            if (status == 'Failed') {
                String problem  = extractTagValue(body, 'problem');
                String fileName = extractTagValue(body, 'fileName');
                if (String.isNotBlank(problem)) {
                    errorMsg = (String.isNotBlank(fileName) ? fileName + ': ' : '') + problem;
                } else {
                    errorMsg = extractTagValue(body, 'errorMessage');
                    if (String.isBlank(errorMsg)) errorMsg = 'Deploy failed. Check target org logs.';
                }
            }

            Integer numberComponentsDeployed = 0;
            Integer numberComponentsTotal    = 0;
            try {
                String deployedStr = extractTagValue(body, 'numberComponentsDeployed');
                String totalStr    = extractTagValue(body, 'numberComponentsTotal');
                if (String.isNotBlank(deployedStr)) numberComponentsDeployed = Integer.valueOf(deployedStr);
                if (String.isNotBlank(totalStr))    numberComponentsTotal    = Integer.valueOf(totalStr);
            } catch (Exception ex) {}

            return new Map<String, Object>{
                'status'                   => status,
                'done'                     => done,
                'errorMessage'             => errorMsg,
                'numberComponentsDeployed' => numberComponentsDeployed,
                'numberComponentsTotal'    => numberComponentsTotal
            };
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('checkDeployStatus: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // UTILITY METHODS
    // ═══════════════════════════════════════════════════════════
    private static HttpResponse dynamicGet(String instanceUrl, String accessToken, String path) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(instanceUrl + path);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(TIMEOUT_MS);
        return new Http().send(req);
    }

    private static AuraHandledException createAuraException(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    private static String sanitizeMetadataType(String metadataType) {
        if (String.isBlank(metadataType)) return 'Other';
        return VALID_METADATA_TYPES.contains(metadataType) ? metadataType : 'Other';
    }

    private static Map<String, String> addAuditFields(Map<String, String> entry, Map<String, Object> r) {
        String createdDate = r.get('CreatedDate') != null ? String.valueOf(r.get('CreatedDate')) : '';
        if (String.isNotBlank(createdDate) && createdDate.length() >= 10) createdDate = createdDate.substring(0, 10);
        entry.put('createdDate', createdDate);
        String modifiedDate = r.get('LastModifiedDate') != null ? String.valueOf(r.get('LastModifiedDate')) : '';
        if (String.isNotBlank(modifiedDate) && modifiedDate.length() >= 10) modifiedDate = modifiedDate.substring(0, 10);
        entry.put('lastModifiedDate', modifiedDate);
        String createdBy = '';
        Object createdByObj = r.get('CreatedBy');
        if (createdByObj != null) { Map<String, Object> cbMap = (Map<String, Object>) createdByObj; createdBy = cbMap.get('Name') != null ? String.valueOf(cbMap.get('Name')) : ''; }
        entry.put('createdBy', createdBy);
        String modifiedBy = '';
        Object modifiedByObj = r.get('LastModifiedBy');
        if (modifiedByObj != null) { Map<String, Object> mbMap = (Map<String, Object>) modifiedByObj; modifiedBy = mbMap.get('Name') != null ? String.valueOf(mbMap.get('Name')) : ''; }
        entry.put('lastModifiedBy', modifiedBy);
        return entry;
    }

    private static String resolveComponentName(Map<String, Object> r, String metadataType, String nameField) {
        String name = '';
        if (metadataType == 'ValidationRule') {
            String vName = String.valueOf(r.get('ValidationName'));
            Object ed    = r.get('EntityDefinition');
            if (ed != null) name = String.valueOf(((Map<String, Object>)ed).get('QualifiedApiName')) + '.' + vName;
        } else if (metadataType == 'CustomField') {
            String fName = String.valueOf(r.get('DeveloperName'));
            Object ed    = r.get('EntityDefinition');
            if (ed != null) {
                String objName = String.valueOf(((Map<String, Object>)ed).get('QualifiedApiName'));
                name = objName + '.' + fName + (fName.endsWith('__c') ? '' : '__c');
            }
        } else if (metadataType == 'CustomObject') {
            name = String.valueOf(r.get('DeveloperName'));
            if (String.isNotBlank(name) && !name.endsWith('__c')) name += '__c';
        } else if (metadataType == 'CustomLabel') {
            name = String.valueOf(r.get('Name'));
        } else {
            name = firstNonNull(new List<String>{ String.valueOf(r.get(nameField)), String.valueOf(r.get('Name')), String.valueOf(r.get('DeveloperName')) });
        }
        return name;
    }

    private static String firstNonNull(List<String> values) {
        for (String v : values) if (String.isNotBlank(v) && v != 'null') return v;
        return '';
    }

    private static String extractComponentName(String filePath) {
        if (String.isBlank(filePath)) return '';
        Integer lastSlash = filePath.lastIndexOf('/');
        String  fileName  = lastSlash >= 0 ? filePath.substring(lastSlash + 1) : filePath;
        fileName = fileName.replace('-meta.xml', '');
        Integer dotIdx = fileName.indexOf('.');
        return dotIdx > 0 ? fileName.substring(0, dotIdx) : fileName;
    }

    private static String extractMetadataType(String filePath) {
        if (String.isBlank(filePath)) return 'Unknown';
        for (String part : filePath.split('/')) if (FOLDER_TYPE_MAP.containsKey(part)) return FOLDER_TYPE_MAP.get(part);
        return 'Metadata';
    }

    private static String formatGitHubDate(String isoDate) {
        if (String.isBlank(isoDate) || isoDate == 'null') return '';
        try {
            List<String> parts = isoDate.substring(0, 10).split('-');
            if (parts.size() < 3) return isoDate;
            Map<String, String> monthMap = new Map<String, String>{
                '01'=>'Jan','02'=>'Feb','03'=>'Mar','04'=>'Apr','05'=>'May','06'=>'Jun',
                '07'=>'Jul','08'=>'Aug','09'=>'Sep','10'=>'Oct','11'=>'Nov','12'=>'Dec'
            };
            return parts[2] + ' ' + (monthMap.containsKey(parts[1]) ? monthMap.get(parts[1]) : parts[1]) + ' ' + parts[0];
        } catch (Exception e) { return isoDate; }
    }

    private static String extractTagValue(String xml, String tagName) {
        if (String.isBlank(xml)) return null;
        Integer s = xml.indexOf('<' + tagName + '>');
        Integer e = xml.indexOf('</' + tagName + '>');
        if (s >= 0 && e > s) return xml.substring(s + tagName.length() + 2, e).trim();
        Pattern p = Pattern.compile('<[^:>]+:' + tagName + '[^>]*>([^<]*)<');
        Matcher m = p.matcher(xml);
        return m.find() ? m.group(1).trim() : null;
    }

    private static String escapeXml(String val) {
        if (String.isBlank(val)) return val;
        return val.replace('&','&amp;').replace('<','&lt;').replace('>','&gt;').replace('"','&quot;').replace('\'','&apos;');
    }
}