public without sharing class PromotionCtrl {

    private static final String  GITHUB_API_BASE = 'https://api.github.com';
    private static final String  API_VERSION     = '64.0';
    private static final Integer TIMEOUT_MS      = 120000;

    private static final Set<String> SKIP_COMPONENTS = new Set<String>{
        'OAuthCallbackCtrl', 'OAuthCallback'
    };

    // ═══════════════════════════════════════════════════════════
    // GET ACTIVE COMMIT FOR USER STORY — Returns ALL active commits
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getActiveCommitInfo(String userStoryId) {
        try {
            // ✅ FIX: Removed LIMIT 1 — fetch ALL active commits
            List<Commit__c> commits = [
                SELECT Id, Branch_Name__c, Commit_ID__c, Commit_Message__c, CreatedDate
                FROM Commit__c
                WHERE User_Story_Name__c = :userStoryId
                AND Status__c = 'Active'
                AND Branch_Name__c != null
                ORDER BY CreatedDate DESC
            ];

            if (commits.isEmpty()) {
                return new Map<String, Object>{ 'hasActiveCommit' => false };
            }

            // Build list of all commits
            List<Map<String, Object>> commitList = new List<Map<String, Object>>();
            for (Commit__c c : commits) {
                commitList.add(new Map<String, Object>{
                    'commitId'      => c.Id,
                    'branchName'    => c.Branch_Name__c,
                    'commitSha'     => c.Commit_ID__c,
                    'commitMessage' => c.Commit_Message__c
                });
            }

            // Return all commits + latest as primary (backward compat)
            return new Map<String, Object>{
                'hasActiveCommit' => true,
                'commits'         => commitList,
                'commitId'        => commits[0].Id,
                'branchName'      => commits[0].Branch_Name__c,
                'commitSha'       => commits[0].Commit_ID__c,
                'commitMessage'   => commits[0].Commit_Message__c + ' (+' + (commits.size() - 1) + ' more)'
            };
        } catch (Exception e) {
            throw createAuraException('getActiveCommitInfo: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // GET ORG DETAILS FROM USER STORY
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled(cacheable=false)
    public static Map<String, String> getOrgDetails(String userStoryId) {
        try {
            User_Story_Name__c us = [
                SELECT Target_Org__c,
                       Target_Org__r.Org_Name__c,
                       Target_Org__r.Org_Type__c,
                       Target_Org__r.Refresh_Token__c,
                       Target_Org__r.Connection_Status__c,
                       GitHub_Connection__c,
                       GitHub_Connection__r.Repo_Owner__c,
                       GitHub_Connection__r.Repo_Name__c,
                       GitHub_Connection__r.Access_Token__c,
                       GitHub_Connection__r.Status__c
                FROM User_Story_Name__c
                WHERE Id = :userStoryId
                LIMIT 1
            ];

            if (us.Target_Org__c == null)
                throw createAuraException('Target Org is not selected on the User Story.');
            if (String.isBlank(us.Target_Org__r.Refresh_Token__c))
                throw createAuraException('Target Org "' + us.Target_Org__r.Org_Name__c + '" is not connected.');
            if (us.GitHub_Connection__c == null)
                throw createAuraException('No GitHub Connection assigned to this User Story.');
            if (us.GitHub_Connection__r.Status__c != 'Connected')
                throw createAuraException('GitHub Connection is not active.');

            return new Map<String, String>{
                'targetOrgName'      => us.Target_Org__r.Org_Name__c,
                'targetOrgType'      => us.Target_Org__r.Org_Type__c,
                'targetRefreshToken' => us.Target_Org__r.Refresh_Token__c,
                'repoOwner'          => us.GitHub_Connection__r.Repo_Owner__c,
                'repoName'           => us.GitHub_Connection__r.Repo_Name__c,
                'githubToken'        => us.GitHub_Connection__r.Access_Token__c
            };
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('getOrgDetails: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // REFRESH ACCESS TOKEN
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static Map<String, String> refreshToken(String refreshToken, String orgType, String orgName) {
        try {
            List<OAuth_Config__mdt> configs = [
                SELECT Client_Id__c, Client_Secret__c
                FROM OAuth_Config__mdt
                WHERE App_Type__c = 'Salesforce'
                AND DeveloperName = :orgName.capitalize()
                LIMIT 1
            ];
            if (configs.isEmpty()) {
                configs = [
                    SELECT Client_Id__c, Client_Secret__c
                    FROM OAuth_Config__mdt
                    WHERE DeveloperName = 'Default'
                    LIMIT 1
                ];
            }

            OAuth_Config__mdt config    = configs[0];
            Boolean           isSandbox = (orgType != null && orgType.toLowerCase() == 'sandbox');
            String tokenEndpoint = isSandbox
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

            if (res.getStatusCode() != 200)
                throw createAuraException('Token refresh failed: ' + respBody);

            Map<String, Object> parsed = (Map<String, Object>) JSON.deserializeUntyped(respBody);
            return new Map<String, String>{
                'accessToken' => String.valueOf(parsed.get('access_token')),
                'instanceUrl' => String.valueOf(parsed.get('instance_url'))
            };
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('refreshToken: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // GET GITHUB ZIP OF FEATURE BRANCH
    // ✅ FIX: Added userStoryId param to filter files by active components only
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String getGitHubBranchZip(
            String repoOwner, String repoName,
            String githubToken, String branchName,
            String userStoryId) {
        try {
            // ✅ FIX: Get ALL active components for this user story across all active commits
            Set<String> allowedComponentNames = new Set<String>();
            List<Map<String, Object>> allActiveComponents = new List<Map<String, Object>>();

            if (String.isNotBlank(userStoryId)) {
                List<Commit__c> activeCommits = [
    SELECT Commit_ID__c
    FROM Commit__c
    WHERE User_Story_Name__c = :userStoryId
    AND Status__c = 'Active'
];

Set<String> activeCommitShas = new Set<String>();
for (Commit__c c : activeCommits) {
    if (String.isNotBlank(c.Commit_ID__c)) {
        activeCommitShas.add(c.Commit_ID__c);
    }
}

List<Component__c> activeComps = new List<Component__c>();
if (!activeCommitShas.isEmpty()) {
    activeComps = [
        SELECT Component_Name__c, Metadata_Type__c
        FROM Component__c
        WHERE User_Story_Name__c = :userStoryId
        AND Commit_ID__c IN :activeCommitShas
    ];
}

                for (Component__c c : activeComps) {
                    if (SKIP_COMPONENTS.contains(c.Component_Name__c)) continue;
                    allowedComponentNames.add(c.Component_Name__c.toLowerCase());
                    allActiveComponents.add(new Map<String, Object>{
                        'Component_Name__c' => c.Component_Name__c,
                        'Metadata_Type__c'  => c.Metadata_Type__c
                    });
                }
            }

            // Get branch SHA
            HttpRequest shaReq = new HttpRequest();
            shaReq.setEndpoint(GITHUB_API_BASE + '/repos/' + repoOwner + '/' + repoName + '/git/ref/heads/' + branchName);
            shaReq.setMethod('GET');
            shaReq.setHeader('Authorization', 'Bearer ' + githubToken);
            shaReq.setHeader('Accept', 'application/vnd.github+json');
            shaReq.setHeader('X-GitHub-Api-Version', '2022-11-28');
            shaReq.setTimeout(TIMEOUT_MS);
            HttpResponse shaRes = new Http().send(shaReq);

            if (shaRes.getStatusCode() != 200)
                throw createAuraException('Branch not found: ' + branchName);

            Map<String, Object> shaData   = (Map<String, Object>) JSON.deserializeUntyped(shaRes.getBody());
            String              commitSha = String.valueOf(((Map<String, Object>) shaData.get('object')).get('sha'));

            // Get tree to find all files
            HttpRequest treeReq = new HttpRequest();
            treeReq.setEndpoint(GITHUB_API_BASE + '/repos/' + repoOwner + '/' + repoName + '/git/trees/' + commitSha + '?recursive=1');
            treeReq.setMethod('GET');
            treeReq.setHeader('Authorization', 'Bearer ' + githubToken);
            treeReq.setHeader('Accept', 'application/vnd.github+json');
            treeReq.setHeader('X-GitHub-Api-Version', '2022-11-28');
            treeReq.setTimeout(TIMEOUT_MS);
            HttpResponse treeRes = new Http().send(treeReq);

            if (treeRes.getStatusCode() != 200)
                throw createAuraException('Tree fetch failed: ' + treeRes.getBody());

            Map<String, Object> treeData = (Map<String, Object>) JSON.deserializeUntyped(treeRes.getBody());
            List<Object>        items    = (List<Object>) treeData.get('tree');

            // ✅ FIX: Filter files — only include files whose component is in allowedComponentNames
            List<Map<String, String>> files = new List<Map<String, String>>();
            for (Object item : items) {
                Map<String, Object> node = (Map<String, Object>) item;
                if (String.valueOf(node.get('type')) != 'blob') continue;

                String path = String.valueOf(node.get('path'));
                String sha  = String.valueOf(node.get('sha'));

                // Always skip package.xml from branch — LWC will build its own
                if (path.endsWith('package.xml')) continue;

                // Extract component name from file path
                String fileName  = path.substringAfterLast('/');
                fileName = fileName.replace('-meta.xml', '');
                Integer dotIdx   = fileName.indexOf('.');
                String  compName = dotIdx > 0 ? fileName.substring(0, dotIdx) : fileName;

                // Skip if component not in our active list
                if (!allowedComponentNames.isEmpty() && !allowedComponentNames.contains(compName.toLowerCase())) {
                    continue;
                }

                // Skip OAuthCallback files
                if (SKIP_COMPONENTS.contains(compName)) continue;

                files.add(new Map<String, String>{ 'path' => path, 'sha' => sha });
            }

            return JSON.serialize(new Map<String, Object>{
                'commitSha'          => commitSha,
                'files'              => files,
                'repoOwner'          => repoOwner,
                'repoName'           => repoName,
                'token'              => githubToken,
                'allActiveComponents'=> allActiveComponents  // ✅ Pass to LWC for package.xml generation
            });

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('getGitHubBranchZip: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // GET FILE CONTENT FROM GITHUB BLOB
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String getFileContent(String repoOwner, String repoName, String githubToken, String fileSha) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(GITHUB_API_BASE + '/repos/' + repoOwner + '/' + repoName + '/git/blobs/' + fileSha);
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + githubToken);
            req.setHeader('Accept', 'application/vnd.github+json');
            req.setHeader('X-GitHub-Api-Version', '2022-11-28');
            req.setTimeout(TIMEOUT_MS);
            HttpResponse res = new Http().send(req);

            if (res.getStatusCode() != 200)
                throw createAuraException('File fetch failed: ' + res.getBody());

            Map<String, Object> data    = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String              content = String.valueOf(data.get('content'));
            content = content.replaceAll('\\n', '').replaceAll('\\r', '');
            return content;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('getFileContent: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // START VALIDATE (checkOnly = true)
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String startValidate(String zipBase64, String accessToken, String instanceUrl) {
        try {
            String soap =
                '<?xml version="1.0" encoding="utf-8"?>' +
                '<soapenv:Envelope xmlns:soapenv="http://schemas.xmlsoap.org/soap/envelope/" xmlns:met="http://soap.sforce.com/2006/04/metadata">' +
                '<soapenv:Header><met:SessionHeader><met:sessionId>' + accessToken + '</met:sessionId></met:SessionHeader></soapenv:Header>' +
                '<soapenv:Body><met:deploy>' +
                '<met:ZipFile>' + zipBase64 + '</met:ZipFile>' +
                '<met:DeployOptions>' +
                '<met:allowMissingFiles>true</met:allowMissingFiles>' +
                '<met:autoUpdatePackage>false</met:autoUpdatePackage>' +
                '<met:checkOnly>true</met:checkOnly>' +
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
                throw createAuraException('Validate Start Failed: ' + (fault != null ? fault : res.getBody()));
            }
            String jobId = extractTagValue(res.getBody(), 'id');
            if (String.isBlank(jobId)) throw createAuraException('Job ID is blank.');
            return jobId;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('startValidate: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // CHECK VALIDATE STATUS
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static Map<String, Object> checkValidateStatus(String jobId, String accessToken, String instanceUrl) {
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
                throw createAuraException('checkValidateStatus Error: ' + (fault != null ? fault : body));
            }

            String  done      = extractTagValue(body, 'done');
            String  success   = extractTagValue(body, 'success');
            Boolean isDone    = done == 'true';
            Boolean isSuccess = success == 'true';

            if (!isDone) {
                String  stateDetail = extractTagValue(body, 'stateDetail');
                Integer compsDone   = 0;
                Integer compsTotal  = 0;
                try {
                    String cd = extractTagValue(body, 'numberComponentsDeployed');
                    String ct = extractTagValue(body, 'numberComponentsTotal');
                    if (cd != null) compsDone  = Integer.valueOf(cd);
                    if (ct != null) compsTotal = Integer.valueOf(ct);
                } catch (Exception ex) {}
                return new Map<String, Object>{
                    'status'          => 'InProgress',
                    'stateDetail'     => String.isNotBlank(stateDetail) ? stateDetail : 'Validating...',
                    'componentsDone'  => compsDone,
                    'componentsTotal' => compsTotal
                };
            }

            // Parse errors
            List<Map<String, String>> errors = new List<Map<String, String>>();
            String bodyWork = body;
            while (bodyWork.contains('<componentFailures>')) {
                Integer s = bodyWork.indexOf('<componentFailures>');
                Integer e = bodyWork.indexOf('</componentFailures>');
                if (s < 0 || e < 0) break;
                String block    = bodyWork.substring(s, e + '</componentFailures>'.length());
                String fileName = extractTagValue(block, 'fileName');
                String problem  = extractTagValue(block, 'problem');
                String lineNum  = extractTagValue(block, 'lineNumber');
                String probType = extractTagValue(block, 'problemType');
                if (String.isNotBlank(problem)) {
                    errors.add(new Map<String, String>{
                        'fileName'    => fileName != null ? fileName : '',
                        'problem'     => problem,
                        'lineNumber'  => lineNum  != null ? lineNum  : '',
                        'problemType' => probType != null ? probType : 'Error'
                    });
                }
                bodyWork = bodyWork.substring(e + '</componentFailures>'.length());
            }

            // Test stats
            Integer testsRun    = 0;
            Integer testsFailed = 0;
            try {
                String tr = extractTagValue(body, 'numTestsRun');
                String tf = extractTagValue(body, 'numFailures');
                if (tr != null) testsRun    = Integer.valueOf(tr);
                if (tf != null) testsFailed = Integer.valueOf(tf);
            } catch (Exception ex) {}

            return new Map<String, Object>{
                'status'      => isSuccess ? 'Passed' : 'Failed',
                'success'     => isSuccess,
                'errors'      => errors,
                'testsRun'    => testsRun,
                'testsFailed' => testsFailed,
                'testsPassed' => testsRun - testsFailed
            };

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('checkValidateStatus: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // SAVE PROMOTION RECORD
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String savePromotion(
            String  userStoryId,
            String  status,
            String  featureBranch,
            String  commitSha,
            Integer totalComponents,
            Integer testsRun,
            Integer testsPassed,
            Integer testsFailed,
            String  errorMessage,
            String  jobId) {
        try {
            List<Promotion__c> existing = [
                SELECT Id FROM Promotion__c
                WHERE User_Story__c = :userStoryId
                AND Status__c NOT IN ('Deployed')
                LIMIT 1
            ];

            Promotion__c promo;
            if (!existing.isEmpty()) {
                promo = existing[0];
                promo.Status__c           = status;
                promo.Feature_Branch__c   = featureBranch;
                promo.Commit_SHA__c       = commitSha;
                promo.Total_Components__c = totalComponents;
                promo.Tests_Run__c        = testsRun;
                promo.Tests_Passed__c     = testsPassed;
                promo.Tests_Failed__c     = testsFailed;
                promo.Validation_Error__c = errorMessage;
                promo.Job_ID__c           = jobId;
                if (status == 'Validated') {
                    promo.Validated_By__c = UserInfo.getUserId();
                    promo.Validated_At__c = DateTime.now();
                }
                update promo;
            } else {
                promo = new Promotion__c(
                    User_Story__c       = userStoryId,
                    Status__c           = status,
                    Feature_Branch__c   = featureBranch,
                    Commit_SHA__c       = commitSha,
                    Total_Components__c = totalComponents,
                    Tests_Run__c        = testsRun,
                    Tests_Passed__c     = testsPassed,
                    Tests_Failed__c     = testsFailed,
                    Validation_Error__c = errorMessage,
                    Job_ID__c           = jobId,
                    Validated_By__c     = status == 'Validated' ? UserInfo.getUserId() : null,
                    Validated_At__c     = status == 'Validated' ? DateTime.now() : null
                );
                insert promo;
            }

            insert new Promotion_History__c(
                Promotion__c        = promo.Id,
                Action__c           = 'Validated',
                Status__c           = status == 'Validated' ? 'Success' : 'Failed',
                Feature_Branch__c   = featureBranch,
                Branch_Name__c      = featureBranch,
                Commit_SHA__c       = commitSha,
                Components_Count__c = totalComponents,
                Performed_By__c     = UserInfo.getUserId(),
                Performed_At__c     = DateTime.now(),
                Error_Message__c    = errorMessage
            );

            return promo.Id;

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('savePromotion: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // CREATE PROMOTION BRANCH FROM FEATURE BRANCH
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String createPromotionBranch(String promotionId, String userStoryId) {
        try {
            Promotion__c promo = [
                SELECT Id, Feature_Branch__c, Commit_SHA__c
                FROM Promotion__c
                WHERE Id = :promotionId
                LIMIT 1
            ];

            User_Story_Name__c us = [
                SELECT Name,
                       GitHub_Connection__r.Repo_Owner__c,
                       GitHub_Connection__r.Repo_Name__c,
                       GitHub_Connection__r.Access_Token__c
                FROM User_Story_Name__c
                WHERE Id = :userStoryId
                LIMIT 1
            ];

            String owner       = us.GitHub_Connection__r.Repo_Owner__c;
            String repo        = us.GitHub_Connection__r.Repo_Name__c;
            String token       = us.GitHub_Connection__r.Access_Token__c;
            String safeName    = us.Name.replaceAll('[^a-zA-Z0-9-]', '-');
            String promoBranch = 'promotion/' + safeName;

            HttpRequest shaReq = new HttpRequest();
            shaReq.setEndpoint(GITHUB_API_BASE + '/repos/' + owner + '/' + repo + '/git/ref/heads/' + promo.Feature_Branch__c);
            shaReq.setMethod('GET');
            shaReq.setHeader('Authorization', 'Bearer ' + token);
            shaReq.setHeader('Accept', 'application/vnd.github+json');
            shaReq.setHeader('X-GitHub-Api-Version', '2022-11-28');
            shaReq.setTimeout(TIMEOUT_MS);
            HttpResponse shaRes = new Http().send(shaReq);

            if (shaRes.getStatusCode() != 200)
                throw createAuraException('Feature branch not found: ' + promo.Feature_Branch__c);

            Map<String, Object> shaData    = (Map<String, Object>) JSON.deserializeUntyped(shaRes.getBody());
            String              featureSha = String.valueOf(((Map<String, Object>) shaData.get('object')).get('sha'));

            HttpRequest branchReq = new HttpRequest();
            branchReq.setEndpoint(GITHUB_API_BASE + '/repos/' + owner + '/' + repo + '/git/refs');
            branchReq.setMethod('POST');
            branchReq.setHeader('Authorization', 'Bearer ' + token);
            branchReq.setHeader('Accept', 'application/vnd.github+json');
            branchReq.setHeader('Content-Type', 'application/json');
            branchReq.setHeader('X-GitHub-Api-Version', '2022-11-28');
            branchReq.setBody(JSON.serialize(new Map<String, String>{
                'ref' => 'refs/heads/' + promoBranch,
                'sha' => featureSha
            }));
            branchReq.setTimeout(TIMEOUT_MS);
            HttpResponse branchRes = new Http().send(branchReq);

            if (branchRes.getStatusCode() != 201 && branchRes.getStatusCode() != 422)
                throw createAuraException('Promotion branch creation failed: ' + branchRes.getBody());

            promo.Promotion_Branch__c = promoBranch;
            promo.Status__c           = 'Deployed';
            promo.Deployed_By__c      = UserInfo.getUserId();
            promo.Deployed_At__c      = DateTime.now();
            update promo;

            insert new Promotion_History__c(
                Promotion__c      = promo.Id,
                Action__c         = 'Deployed',
                Status__c         = 'Success',
                Feature_Branch__c = promo.Feature_Branch__c,
                Branch_Name__c    = promoBranch,
                Commit_SHA__c     = featureSha,
                Performed_By__c   = UserInfo.getUserId(),
                Performed_At__c   = DateTime.now()
            );

            return promoBranch;

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            try {
                List<Promotion__c> promos = [SELECT Id FROM Promotion__c WHERE Id = :promotionId LIMIT 1];
                if (!promos.isEmpty()) {
                    promos[0].Status__c = 'Deploy Failed';
                    update promos[0];
                    insert new Promotion_History__c(
                        Promotion__c     = promotionId,
                        Action__c        = 'Deployed',
                        Status__c        = 'Failed',
                        Performed_By__c  = UserInfo.getUserId(),
                        Performed_At__c  = DateTime.now(),
                        Error_Message__c = e.getMessage()
                    );
                }
            } catch (Exception ex) {}
            throw createAuraException('createPromotionBranch: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // GET PROMOTION DETAILS
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled(cacheable=false)
    public static Map<String, Object> getPromotionDetails(String promotionId) {
        try {
            Promotion__c promo = [
                SELECT Id, Name, Status__c,
                       Feature_Branch__c, Promotion_Branch__c,
                       Validated_At__c, Deployed_At__c,
                       Validated_By__r.Name, Deployed_By__r.Name,
                       Total_Components__c, Tests_Run__c,
                       Tests_Passed__c, Tests_Failed__c,
                       Validation_Error__c, Commit_SHA__c,
                       User_Story__c, User_Story__r.Name
                FROM Promotion__c
                WHERE Id = :promotionId
                LIMIT 1
            ];

            return new Map<String, Object>{
                'id'              => promo.Id,
                'name'            => promo.Name,
                'status'          => promo.Status__c,
                'featureBranch'   => promo.Feature_Branch__c,
                'promotionBranch' => promo.Promotion_Branch__c,
                'validatedAt'     => promo.Validated_At__c != null ? String.valueOf(promo.Validated_At__c) : '',
                'deployedAt'      => promo.Deployed_At__c  != null ? String.valueOf(promo.Deployed_At__c)  : '',
                'validatedBy'     => promo.Validated_By__r != null ? promo.Validated_By__r.Name : '',
                'deployedBy'      => promo.Deployed_By__r  != null ? promo.Deployed_By__r.Name  : '',
                'totalComponents' => promo.Total_Components__c,
                'testsRun'        => promo.Tests_Run__c,
                'testsPassed'     => promo.Tests_Passed__c,
                'testsFailed'     => promo.Tests_Failed__c,
                'validationError' => promo.Validation_Error__c,
                'commitSha'       => promo.Commit_SHA__c,
                'userStoryId'     => promo.User_Story__c,
                'userStoryName'   => promo.User_Story__r != null ? promo.User_Story__r.Name : '',
                'canDeploy'       => promo.Status__c == 'Validated'
            };
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createAuraException('getPromotionDetails: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // UTILITIES
    // ═══════════════════════════════════════════════════════════
    private static AuraHandledException createAuraException(String message) {
        AuraHandledException e = new AuraHandledException(message);
        e.setMessage(message);
        return e;
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
}