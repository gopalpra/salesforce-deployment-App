public without sharing class DeploymentToolCtrl {

    private static final String  TARGET_NC    = 'TargetOrg_NC1';
    private static final String  SOURCE_NC    = 'SourceOrg_NC1';
    private static final String  GITHUB_NC    = 'GitHub_NC';
    private static final String  GITHUB_OWNER = 'gopalpra';
    private static final String  GITHUB_REPO  = 'salesforce-deployments';
    private static final String  API_VERSION  = '64.0';
    private static final Integer TIMEOUT_MS   = 120000;
    private static final Integer BATCH_SIZE   = 10;

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

    private static HttpResponse githubGet(String path) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + GITHUB_NC + path);
        req.setMethod('GET');
        req.setHeader('Accept', 'application/vnd.github+json');
        req.setHeader('X-GitHub-Api-Version', '2022-11-28');
        req.setTimeout(TIMEOUT_MS);
        return new Http().send(req);
    }

    private static HttpResponse githubPost(String method, String path, Object bodyObj) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + GITHUB_NC + path);
        req.setMethod(method);
        req.setHeader('Accept', 'application/vnd.github+json');
        req.setHeader('Content-Type', 'application/json');
        req.setHeader('X-GitHub-Api-Version', '2022-11-28');
        req.setBody(JSON.serialize(bodyObj));
        req.setTimeout(TIMEOUT_MS);
        return new Http().send(req);
    }

    private static HttpResponse sourceGet(String path) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + SOURCE_NC + path);
        req.setMethod('GET');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(TIMEOUT_MS);
        return new Http().send(req);
    }

    private static HttpResponse sourceSoap(String soapBody) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('callout:' + SOURCE_NC + '/services/Soap/m/' + API_VERSION);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'text/xml; charset=UTF-8');
        req.setHeader('SOAPAction', '""');
        req.setBody(soapBody);
        req.setTimeout(TIMEOUT_MS);
        return new Http().send(req);
    }

    private static String repoPath(String suffix) {
        return '/repos/' + GITHUB_OWNER + '/' + GITHUB_REPO + suffix;
    }

    private static AuraHandledException createAuraException(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
    }

    private static void checkGitHubRateLimit(HttpResponse res, String context) {
        if (res.getStatusCode() == 429)
            throw createAuraException(context + ': GitHub rate limit hit. Please wait and retry.');
    }

    private static String sanitizeMetadataType(String metadataType) {
        if (String.isBlank(metadataType)) return 'Other';
        return VALID_METADATA_TYPES.contains(metadataType) ? metadataType : 'Other';
    }

    // ═══════════════════════════════════════════════════════════
    // getComponents — returns name, label, audit fields
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled(cacheable=true)
    public static List<Map<String, String>> getComponents(String metadataType) {
        try {
            
            if (metadataType == 'CustomMetadataType') {
                HttpResponse res = sourceGet(
                    '/services/data/v' + API_VERSION +
                    '/tooling/query?q=' + EncodingUtil.urlEncode(
                        'SELECT Id, DeveloperName, QualifiedApiName, Label ' +
                        'FROM EntityDefinition ' +
                        'WHERE QualifiedApiName LIKE \'%__mdt\'',
                        'UTF-8'
                    )
                );
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
                    if (String.isNotBlank(id) && String.isNotBlank(name) && name != 'null') {
                        result.add(new Map<String, String>{
                            'id'    => id,
                            'name'  => name,
                            'label' => r.get('Label') != null ? String.valueOf(r.get('Label')) : name
                        });
                    }
                }
                return result;
            }

           
            if (metadataType == 'CustomLabel') {
                HttpResponse clRes = sourceGet(
                    '/services/data/v' + API_VERSION +
                    '/tooling/query?q=' + EncodingUtil.urlEncode(
                        'SELECT Id, Name, MasterLabel FROM CustomLabel', 'UTF-8')
                );
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
                        String              lbl  = r.get('MasterLabel') != null
                                                   ? String.valueOf(r.get('MasterLabel')) : name;
                        if (String.isNotBlank(id) && String.isNotBlank(name) && name != 'null') {
                            clResult.add(new Map<String, String>{
                                'id' => id, 'name' => name, 'label' => lbl
                            });
                        }
                    }
                }
                return clResult;
            }

            // ── All other types ──
            String nameField  = METADATA_FIELD_MAP.containsKey(metadataType) ? METADATA_FIELD_MAP.get(metadataType) : 'Name';
            String labelField = LABEL_FIELD_MAP.containsKey(metadataType)     ? LABEL_FIELD_MAP.get(metadataType)    : '';

            String selectFields = 'Id,' + nameField;

            // Add label field only if different from name field and not blank
            if (String.isNotBlank(labelField) && labelField != nameField) {
                selectFields += ',' + labelField;
            }

            if (metadataType == 'ValidationRule' || metadataType == 'CustomField') {
                selectFields += ',EntityDefinition.QualifiedApiName';
            }

            if (AUDIT_SUPPORTED.contains(metadataType)) {
                selectFields += ',CreatedDate,LastModifiedDate,CreatedBy.Name,LastModifiedBy.Name';
            }

            String query    = 'SELECT ' + selectFields + ' FROM ' + metadataType;
            String endpoint = '/services/data/v' + API_VERSION + '/tooling/query?q=' +
                              EncodingUtil.urlEncode(query, 'UTF-8');

            HttpResponse res = sourceGet(endpoint);

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

                    // Resolve label
                    String labelValue = '';
                    if (String.isNotBlank(labelField) && r.get(labelField) != null) {
                        labelValue = String.valueOf(r.get(labelField));
                        if (labelValue == 'null') labelValue = '';
                    }
                    if (String.isBlank(labelValue)) labelValue = name;
                    entry.put('label', labelValue);

                    if (AUDIT_SUPPORTED.contains(metadataType)) {
                        entry = addAuditFields(entry, r);
                    }
                    result.add(entry);
                }
            }
            return result;

        } catch (Exception e) {
            throw createAuraException('getComponents Error: ' + e.getMessage());
        }
    }

    private static Map<String, String> addAuditFields(Map<String, String> entry, Map<String, Object> r) {
        String createdDate = r.get('CreatedDate') != null ? String.valueOf(r.get('CreatedDate')) : '';
        if (String.isNotBlank(createdDate) && createdDate.length() >= 10)
            createdDate = createdDate.substring(0, 10);
        entry.put('createdDate', createdDate);

        String modifiedDate = r.get('LastModifiedDate') != null ? String.valueOf(r.get('LastModifiedDate')) : '';
        if (String.isNotBlank(modifiedDate) && modifiedDate.length() >= 10)
            modifiedDate = modifiedDate.substring(0, 10);
        entry.put('lastModifiedDate', modifiedDate);

        String createdBy = '';
        Object createdByObj = r.get('CreatedBy');
        if (createdByObj != null) {
            Map<String, Object> cbMap = (Map<String, Object>) createdByObj;
            createdBy = cbMap.get('Name') != null ? String.valueOf(cbMap.get('Name')) : '';
        }
        entry.put('createdBy', createdBy);

        String modifiedBy = '';
        Object modifiedByObj = r.get('LastModifiedBy');
        if (modifiedByObj != null) {
            Map<String, Object> mbMap = (Map<String, Object>) modifiedByObj;
            modifiedBy = mbMap.get('Name') != null ? String.valueOf(mbMap.get('Name')) : '';
        }
        entry.put('lastModifiedBy', modifiedBy);

        return entry;
    }

    private static String resolveComponentName(Map<String, Object> r, String metadataType, String nameField) {
        String name = '';
        if (metadataType == 'ValidationRule') {
            String vName     = String.valueOf(r.get('ValidationName'));
            Object entityDef = r.get('EntityDefinition');
            if (entityDef != null) {
                String objName = String.valueOf(((Map<String, Object>)entityDef).get('QualifiedApiName'));
                name = objName + '.' + vName;
            }
        } else if (metadataType == 'CustomField') {
            String fName     = String.valueOf(r.get('DeveloperName'));
            Object entityDef = r.get('EntityDefinition');
            if (entityDef != null) {
                String objName = String.valueOf(((Map<String, Object>)entityDef).get('QualifiedApiName'));
                name = objName + '.' + fName + (fName.endsWith('__c') ? '' : '__c');
            }
        } else if (metadataType == 'CustomObject') {
            name = String.valueOf(r.get('DeveloperName'));
            if (String.isNotBlank(name) && !name.endsWith('__c')) name += '__c';
        } else if (metadataType == 'CustomLabel') {
            name = String.valueOf(r.get('Name'));
        } else {
            name = firstNonNull(new List<String>{
                String.valueOf(r.get(nameField)),
                String.valueOf(r.get('Name')),
                String.valueOf(r.get('DeveloperName'))
            });
        }
        return name;
    }

    private static String firstNonNull(List<String> values) {
        for (String v : values)
            if (String.isNotBlank(v) && v != 'null') return v;
        return '';
    }

    // ═══════════════════════════════════════════════════════════
    // getComponentDependencies
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static List<Map<String, String>> getComponentDependencies(List<String> componentIds) {
        if (componentIds == null || componentIds.isEmpty()) return new List<Map<String, String>>();

        try {
            List<String> quotedIds = new List<String>();
            for (String cid : componentIds) quotedIds.add('\'' + cid + '\'');
            String inClause = String.join(quotedIds, ',');

            String query =
                'SELECT MetadataComponentName, MetadataComponentType, ' +
                'RefMetadataComponentName, RefMetadataComponentType ' +
                'FROM MetadataComponentDependency ' +
                'WHERE MetadataComponentId IN (' + inClause + ')';

            HttpResponse res = sourceGet('/services/data/v' + API_VERSION +
                '/tooling/query?q=' + EncodingUtil.urlEncode(query, 'UTF-8'));

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

                if (String.isBlank(refName) || String.isBlank(refType) ||
                    refName == 'null' || refType == 'null') continue;

                if (refType == 'StandardEntity') {
                    if (!refName.contains('__c') && !refName.contains('__mdt') &&
                        !refName.contains('__e') && !refName.contains('__b')) continue;
                    refType = refName.contains('__mdt') ? 'CustomMetadataType' : 'CustomObject';
                }

                if (!DEPLOYABLE_TYPES.contains(refType)) continue;
                if (refType == 'CustomField' && !refName.contains('__')) continue;

                String key = refType + '#' + refName;
                if (!uniqueKeys.contains(key)) {
                    uniqueKeys.add(key);
                    dependencies.add(new Map<String, String>{
                        'metadataType' => refType,
                        'name'         => refName,
                        'requiredBy'   => srcName
                    });
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
    // startRetrieve
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String startRetrieve(List<String> componentNames, String metadataType) {
        try {
            String retrieveType = metadataType == 'FlowDefinition'     ? 'Flow'         :
                                  metadataType == 'CustomMetadataType' ? 'CustomObject' :
                                  metadataType;

            Set<String> membersToRetrieve = new Set<String>(componentNames);
            Set<String> parentObjects     = new Set<String>();

            for (String name : componentNames) {
                if (name.contains('.')) {
                    String parent = name.split('\\.')[0];
                    if (String.isNotBlank(parent)) parentObjects.add(parent);
                }
                if (name.endsWith('__mdt')) parentObjects.add(name);
            }

            String membersXml = '';
            for (String m : membersToRetrieve)
                membersXml += '<met:members>' + escapeXml(m) + '</met:members>';

            String extraTypesXml = '';
            if (!parentObjects.isEmpty()) {
                String objMembers = '';
                for (String obj : parentObjects)
                    objMembers += '<met:members>' + escapeXml(obj) + '</met:members>';
                extraTypesXml = '<met:types>' + objMembers + '<met:name>CustomObject</met:name></met:types>';
            }

            String soap =
                '<?xml version="1.0" encoding="utf-8"?>' +
                '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"' +
                ' xmlns:met="http://soap.sforce.com/2006/04/metadata">' +
                '<soapenv:Header><met:SessionHeader>' +
                '<met:sessionId>{!$Credential.OAuthToken}</met:sessionId>' +
                '</met:SessionHeader></soapenv:Header>' +
                '<soapenv:Body><met:retrieve><met:retrieveRequest>' +
                '<met:apiVersion>' + API_VERSION + '</met:apiVersion>' +
                '<met:singlePackage>true</met:singlePackage>' +
                '<met:unpackaged>' +
                '<met:types>' + membersXml + '<met:name>' + retrieveType + '</met:name></met:types>' +
                extraTypesXml +
                '<met:version>' + API_VERSION + '</met:version>' +
                '</met:unpackaged>' +
                '</met:retrieveRequest></met:retrieve></soapenv:Body>' +
                '</soapenv:Envelope>';

            HttpResponse res = sourceSoap(soap);
            if (res.getStatusCode() != 200) {
                String fault = extractTagValue(res.getBody(), 'faultstring');
                throw createAuraException('Retrieve Failed: ' + (fault != null ? fault : res.getBody()));
            }

            return extractTagValue(res.getBody(), 'id');
        } catch (Exception e) {
            throw createAuraException(e.getMessage());
        }
    }

    @AuraEnabled
    public static Map<String, Object> checkRetrieveStatus(String jobId) {
        try {
            String soap =
                '<?xml version="1.0" encoding="utf-8"?>' +
                '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/"' +
                ' xmlns:met="http://soap.sforce.com/2006/04/metadata">' +
                '<soapenv:Header><met:SessionHeader>' +
                '<met:sessionId>{!$Credential.OAuthToken}</met:sessionId>' +
                '</met:SessionHeader></soapenv:Header>' +
                '<soapenv:Body><met:checkRetrieveStatus>' +
                '<met:asyncProcessId>' + jobId + '</met:asyncProcessId>' +
                '<met:includeZip>true</met:includeZip>' +
                '</met:checkRetrieveStatus></soapenv:Body>' +
                '</soapenv:Envelope>';

            HttpResponse res  = sourceSoap(soap);
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
                return new Map<String, Object>{
                    'status'  => 'Failed',
                    'message' => String.isNotBlank(errMsg) ? errMsg : 'Unknown retrieve error'
                };
            }
            return new Map<String, Object>{ 'status' => String.isNotBlank(status) ? status : 'InProgress' };
        } catch (Exception e) {
            throw createAuraException('checkRetrieveStatus: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static String getMainBranchSha() {
        try {
            HttpResponse res = githubGet(repoPath('/git/ref/heads/main'));
            checkGitHubRateLimit(res, 'getMainBranchSha');
            if (res.getStatusCode() != 200)
                throw createAuraException('GitHub SHA fetch failed (' + res.getStatusCode() + '): ' + res.getBody());
            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            Map<String, Object> obj    = (Map<String, Object>) parsed.get('object');
            String sha = String.valueOf(obj.get('sha'));
            if (String.isBlank(sha) || sha == 'null') throw createAuraException('SHA value is empty.');
            return sha;
        } catch (Exception e) {
            throw createAuraException('getMainBranchSha: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static String createFeatureBranch(String branchName, String sha) {
        try {
            HttpResponse res = githubPost('POST', repoPath('/git/refs'), new Map<String, String>{
                'ref' => 'refs/heads/' + branchName, 'sha' => sha
            });
            checkGitHubRateLimit(res, 'createFeatureBranch');
            if (res.getStatusCode() != 201 && res.getStatusCode() != 422)
                throw createAuraException('Branch create failed (' + res.getStatusCode() + '): ' + res.getBody());
            return branchName;
        } catch (Exception e) {
            throw createAuraException('createFeatureBranch: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static Boolean pushFileToGitHub(String filePath, String base64Content,
                                           String branchName, String commitMessage) {
        try {
            String existingSha  = getFileSha(filePath, branchName);
            Map<String, Object> bodyMap = new Map<String, Object>{
                'message' => commitMessage, 'content' => base64Content, 'branch' => branchName
            };
            if (String.isNotBlank(existingSha)) bodyMap.put('sha', existingSha);
            String encodedPath = EncodingUtil.urlEncode(filePath, 'UTF-8');
            HttpResponse res   = githubPost('PUT', repoPath('/contents/' + encodedPath), bodyMap);
            checkGitHubRateLimit(res, 'pushFileToGitHub');
            if (res.getStatusCode() != 200 && res.getStatusCode() != 201)
                throw createAuraException('File push failed [' + filePath + '] (' + res.getStatusCode() + '): ' + res.getBody());
            return true;
        } catch (Exception e) {
            throw createAuraException('pushFileToGitHub: ' + e.getMessage());
        }
    }

    private static String getFileSha(String filePath, String branchName) {
        try {
            String encodedPath = EncodingUtil.urlEncode(filePath, 'UTF-8');
            HttpResponse res   = githubGet(repoPath('/contents/' + encodedPath + '?ref=' + branchName));
            if (res.getStatusCode() == 200) {
                Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                if (parsed != null && parsed.containsKey('sha')) return String.valueOf(parsed.get('sha'));
            }
            return null;
        } catch (Exception e) { return null; }
    }

    @AuraEnabled
    public static Boolean pushMultipleFilesToGitHub(String branchName, String commitMessage,
                                                    List<Map<String, String>> files) {
        try {
            HttpResponse        refRes          = githubGet(repoPath('/git/ref/heads/' + branchName));
            checkGitHubRateLimit(refRes, 'Get Ref');
            Map<String, Object> refParsed       = (Map<String, Object>) JSON.deserializeUntyped(refRes.getBody());
            String              latestCommitSha = String.valueOf(((Map<String, Object>) refParsed.get('object')).get('sha'));

            HttpResponse        commitRes    = githubGet(repoPath('/git/commits/' + latestCommitSha));
            checkGitHubRateLimit(commitRes, 'Get Commit');
            Map<String, Object> commitParsed = (Map<String, Object>) JSON.deserializeUntyped(commitRes.getBody());
            String              baseTreeSha  = String.valueOf(((Map<String, Object>) commitParsed.get('tree')).get('sha'));

            List<Map<String, Object>> treeNodes = new List<Map<String, Object>>();
            for (Map<String, String> file : files) {
                HttpResponse        blobRes    = githubPost('POST', repoPath('/git/blobs'),
                    new Map<String, Object>{ 'content' => file.get('base64Content'), 'encoding' => 'base64' });
                Map<String, Object> blobParsed = (Map<String, Object>) JSON.deserializeUntyped(blobRes.getBody());
                treeNodes.add(new Map<String, Object>{
                    'path' => file.get('filePath'), 'mode' => '100644',
                    'type' => 'blob', 'sha' => String.valueOf(blobParsed.get('sha'))
                });
            }

            HttpResponse newTreeRes = githubPost('POST', repoPath('/git/trees'),
                new Map<String, Object>{ 'base_tree' => baseTreeSha, 'tree' => treeNodes });
            String newTreeSha = String.valueOf(
                ((Map<String, Object>) JSON.deserializeUntyped(newTreeRes.getBody())).get('sha'));

            HttpResponse newCommitRes = githubPost('POST', repoPath('/git/commits'),
                new Map<String, Object>{
                    'message' => commitMessage, 'tree' => newTreeSha,
                    'parents' => new List<String>{ latestCommitSha }
                });
            String newCommitSha = String.valueOf(
                ((Map<String, Object>) JSON.deserializeUntyped(newCommitRes.getBody())).get('sha'));

            HttpResponse updateRefRes = githubPost('PATCH', repoPath('/git/refs/heads/' + branchName),
                new Map<String, Object>{ 'sha' => newCommitSha });
            checkGitHubRateLimit(updateRefRes, 'Update Ref');
            return true;
        } catch (Exception e) {
            throw createAuraException('pushMultipleFilesToGitHub: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static String createPullRequest(String branchName, String title) {
        try {
            HttpResponse res = githubPost('POST', repoPath('/pulls'), new Map<String, String>{
                'title' => title, 'head' => branchName, 'base' => 'main',
                'body'  => 'Auto-generated PR by Deployment Tool\nBranch: ' + branchName
            });
            checkGitHubRateLimit(res, 'createPullRequest');
            if (res.getStatusCode() != 201)
                throw createAuraException('PR creation failed (' + res.getStatusCode() + '): ' + res.getBody());
            Map<String, Object> parsed   = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String              prNumber = String.valueOf(parsed.get('number'));
            if (String.isBlank(prNumber) || prNumber == 'null') throw createAuraException('PR number blank.');
            return prNumber;
        } catch (Exception e) {
            throw createAuraException('createPullRequest: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static Boolean mergePullRequest(String prNumber) {
        try {
            HttpResponse res = githubPost('PUT', repoPath('/pulls/' + prNumber + '/merge'),
                new Map<String, String>{ 'commit_title' => 'Auto-merge by Deployment Tool', 'merge_method' => 'squash' });
            checkGitHubRateLimit(res, 'mergePullRequest');
            if (res.getStatusCode() != 200)
                throw createAuraException('PR merge failed (' + res.getStatusCode() + '): ' + res.getBody());
            return true;
        } catch (Exception e) {
            throw createAuraException('mergePullRequest: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static List<Map<String, Object>> getPreviousCommits() {
        try {
            HttpResponse res = githubGet(repoPath('/pulls?state=closed&per_page=20&sort=updated&direction=desc'));
            checkGitHubRateLimit(res, 'getPreviousCommits');
            if (res.getStatusCode() != 200)
                throw createAuraException('PR fetch failed (' + res.getStatusCode() + '): ' + res.getBody());

            List<Object>              pullRequests = (List<Object>) JSON.deserializeUntyped(res.getBody());
            List<Map<String, Object>> result       = new List<Map<String, Object>>();
            for (Object prObj : pullRequests) {
                Map<String, Object> pr = (Map<String, Object>) prObj;
                if (pr.get('merged_at') == null) continue;
                Integer prNumber = (Integer) pr.get('number');
                result.add(new Map<String, Object>{
                    'number'   => prNumber,
                    'title'    => String.valueOf(pr.get('title')),
                    'mergedAt' => formatGitHubDate(String.valueOf(pr.get('merged_at'))),
                    'files'    => getPrFiles(prNumber)
                });
            }
            return result;
        } catch (Exception e) {
            throw createAuraException('getPreviousCommits: ' + e.getMessage());
        }
    }

    private static List<Map<String, Object>> getPrFiles(Integer prNumber) {
        List<Map<String, Object>> files = new List<Map<String, Object>>();
        try {
            HttpResponse res = githubGet(repoPath('/pulls/' + prNumber + '/files?per_page=100'));
            if (res.getStatusCode() != 200) return files;
            List<Object> rawFiles = (List<Object>) JSON.deserializeUntyped(res.getBody());
            for (Object f : rawFiles) {
                Map<String, Object> fileMap  = (Map<String, Object>) f;
                String              filePath = String.valueOf(fileMap.get('filename'));
                if (filePath == null || filePath.endsWith('package.xml')) continue;
                String componentName = extractComponentName(filePath);
                if (String.isNotBlank(componentName)) {
                    files.add(new Map<String, Object>{
                        'path' => filePath, 'name' => componentName,
                        'metadataType' => extractMetadataType(filePath)
                    });
                }
            }
        } catch (Exception e) { }
        return files;
    }

    @AuraEnabled
    public static String saveDeploymentLog(String prNumber, String prTitle, String branchName,
                                           List<Map<String, String>> components) {
        try {
            Deployment_Log__c log = new Deployment_Log__c(
                PR_Number__c        = prNumber,
                PR_Title__c         = prTitle,
                Branch_Name__c      = branchName,
                PR_URL__c           = 'https://github.com/' + GITHUB_OWNER + '/' + GITHUB_REPO + '/pull/' + prNumber,
                Status__c           = 'In Progress',
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
        } catch (Exception e) {
            throw createAuraException('saveDeploymentLog: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static String syncDeploymentStatus(String logId, String branchName) {
        try {
            String finalStatus = 'Failed';
            HttpResponse res = githubGet(repoPath(
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
        } catch (Exception e) {
            throw createAuraException('syncDeploymentStatus: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // getTargetComponents — for Delete tab
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled(cacheable=false)
    public static List<Map<String, String>> getTargetComponents(String metadataType) {
        try {
            String nameField = METADATA_FIELD_MAP.containsKey(metadataType) ? METADATA_FIELD_MAP.get(metadataType) : 'Name';
            String query     = 'SELECT Id,' + nameField + ' FROM ' + metadataType;

            HttpRequest req = new HttpRequest();  
            req.setEndpoint('callout:' + TARGET_NC +
                '/services/data/v' + API_VERSION + '/tooling/query?q=' +
                EncodingUtil.urlEncode(query, 'UTF-8'));
            req.setMethod('GET');
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(TIMEOUT_MS);
            HttpResponse res = new Http().send(req);

            if (res.getStatusCode() != 200)
                throw createAuraException('Target Org fetch error (' + res.getStatusCode() + '): ' + res.getBody());

            Map<String, Object>       parsed  = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            List<Object>              records = (List<Object>) parsed.get('records');
            List<Map<String, String>> result  = new List<Map<String, String>>();
            if (records == null || records.isEmpty()) return result;

            for (Object rec : records) {
                Map<String, Object> r    = (Map<String, Object>) rec;
                String              id   = String.valueOf(r.get('Id'));
                String              name = resolveComponentName(r, metadataType, nameField);
                if (String.isNotBlank(id) && String.isNotBlank(name) && name != 'null') {
                    result.add(new Map<String, String>{ 'id' => id, 'name' => name });
                }
            }
            return result;
        } catch (Exception e) {
            throw createAuraException('getTargetComponents: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // buildDestructiveXml
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String buildDestructiveXml(List<Map<String, String>> componentsToDelete) {
        Map<String, List<String>> byType = new Map<String, List<String>>();
        for (Map<String, String> comp : componentsToDelete) {
            String t = comp.get('metadataType'), n = comp.get('name');
            if (t == 'FlowDefinition') t = 'Flow';
            if (!byType.containsKey(t)) byType.put(t, new List<String>());
            byType.get(t).add(n);
        }
        String typesXml = '';
        for (String t : byType.keySet()) {
            String membersXml = '';
            for (String m : byType.get(t)) membersXml += '    <members>' + escapeXml(m) + '</members>\n';
            typesXml += '  <types>\n' + membersXml + '    <name>' + t + '</name>\n  </types>\n';
        }
        return '<?xml version="1.0" encoding="UTF-8"?>\n' +
               '<Package xmlns="http://soap.sforce.com/2006/04/metadata">\n' +
               typesXml + '  <version>' + API_VERSION + '</version>\n</Package>';
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
        for (String part : filePath.split('/'))
            if (FOLDER_TYPE_MAP.containsKey(part)) return FOLDER_TYPE_MAP.get(part);
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
            String month = monthMap.containsKey(parts[1]) ? monthMap.get(parts[1]) : parts[1];
            return parts[2] + ' ' + month + ' ' + parts[0];
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
        return val.replace('&','&amp;').replace('<','&lt;')
                  .replace('>','&gt;').replace('"','&quot;').replace('\'','&apos;');
    }
}
