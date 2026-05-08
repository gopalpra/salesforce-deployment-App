public without sharing class GitHubManagerCtrl {

    private static final Integer TIMEOUT_MS = 120000;

    private static OAuth_Config__mdt getGitHubConfig() {
    List<OAuth_Config__mdt> configs = [
        SELECT Client_Id__c, Client_Secret__c, Callback_Url__c
        FROM OAuth_Config__mdt
        WHERE App_Type__c = 'GitHub'
        LIMIT 1
    ];
    if (configs.isEmpty()) {
        throw new AuraHandledException(
            'No GitHub OAuth App configured. Please contact administrator.'
        );
    }
    return configs[0];
}

    // ═══════════════════════════════════════════════════════════
    // Step 1 — Get GitHub Authorization URL
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
   public static String getAuthorizationUrl(String stateToken) {
    try {
        OAuth_Config__mdt config = getGitHubConfig();

            String url = 'https://github.com/login/oauth/authorize'
                + '?client_id='    + EncodingUtil.urlEncode(config.Client_Id__c,    'UTF-8')
                + '&redirect_uri=' + EncodingUtil.urlEncode(config.Callback_Url__c, 'UTF-8')
                + '&scope='        + EncodingUtil.urlEncode('repo user',             'UTF-8')
                + '&state='        + EncodingUtil.urlEncode(stateToken,              'UTF-8');

            return url;
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('getAuthorizationUrl error: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Step 2 — Exchange code for token and save
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static Map<String, Object> exchangeCodeAndSave(
        String authCode,
        String connectionName,
        String repoOwner,
        String repoName
    ) {
        try {
          OAuth_Config__mdt config = getGitHubConfig();

            HttpRequest req = new HttpRequest();
            req.setEndpoint('https://github.com/login/oauth/access_token');
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            req.setHeader('Accept', 'application/json');
            req.setTimeout(TIMEOUT_MS);
            req.setBody(
                'client_id='        + EncodingUtil.urlEncode(config.Client_Id__c,    'UTF-8')
                + '&client_secret=' + EncodingUtil.urlEncode(config.Client_Secret__c,'UTF-8')
                + '&code='          + EncodingUtil.urlEncode(authCode,               'UTF-8')
                + '&redirect_uri='  + EncodingUtil.urlEncode(config.Callback_Url__c, 'UTF-8')
            );

            HttpResponse res = new Http().send(req);

            if (res.getStatusCode() != 200) {
                throw new AuraHandledException(
                    'Token exchange failed (' + res.getStatusCode() + '): ' + res.getBody()
                );
            }

            Map<String, Object> tokenData  = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String              accessToken = String.valueOf(tokenData.get('access_token'));

            if (String.isBlank(accessToken) || accessToken == 'null') {
                throw new AuraHandledException('No access token received: ' + res.getBody());
            }

            // Fetch GitHub user info
            String githubUsername = fetchGitHubUsername(accessToken);

            // Verify repository access
            verifyRepoAccess(accessToken, repoOwner, repoName);

            // Check duplicate repo
            List<GitHub_Connection__c> existingRepo = [
                SELECT Id, Name FROM GitHub_Connection__c
                WHERE Repo_Owner__c = :repoOwner
                AND Repo_Name__c    = :repoName
                AND Name           != :connectionName
                LIMIT 1
            ];
            if (!existingRepo.isEmpty()) {
                throw new AuraHandledException(
                    'Repository "' + repoOwner + '/' + repoName + '" is already connected as "' + existingRepo[0].Name + '".'
                );
            }

            // Save to custom object
            GitHub_Connection__c conn = upsertConnection(
                connectionName, githubUsername, accessToken, repoOwner, repoName
            );

            return new Map<String, Object>{
                'success'      => true,
                'username'     => githubUsername,
                'connectionId' => conn.Id,
                'message'      => 'Connected successfully: ' + githubUsername
            };

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('exchangeCodeAndSave error: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Fetch GitHub username from API
    // ═══════════════════════════════════════════════════════════
    private static String fetchGitHubUsername(String accessToken) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint('https://api.github.com/user');
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + accessToken);
            req.setHeader('Accept', 'application/vnd.github+json');
            req.setTimeout(TIMEOUT_MS);

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() == 200) {
                Map<String, Object> info = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                return info.get('login') != null ? String.valueOf(info.get('login')) : 'Unknown';
            }
            return 'Unknown';
        } catch (Exception e) {
            return 'Unknown';
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Upsert connection record
    // ═══════════════════════════════════════════════════════════
    private static GitHub_Connection__c upsertConnection(
        String connectionName,
        String githubUsername,
        String accessToken,
        String repoOwner,
        String repoName
    ) {
        List<GitHub_Connection__c> existing = [
            SELECT Id FROM GitHub_Connection__c
            WHERE Name = :connectionName
            LIMIT 1
        ];

        GitHub_Connection__c conn = existing.isEmpty() ? new GitHub_Connection__c() : existing[0];
        conn.Name               = connectionName;
        conn.GitHub_Username__c = githubUsername;
        conn.Access_Token__c    = accessToken;
        conn.Repo_Owner__c      = repoOwner;
        conn.Repo_Name__c       = repoName;
        conn.Status__c          = 'Connected';
        conn.Connected_By__c    = UserInfo.getUserId();

        upsert conn;
        return conn;
    }

    // ═══════════════════════════════════════════════════════════
    // Get saved connections
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled(cacheable=false)
    public static List<GitHub_Connection__c> getSavedConnections() {
        return [
            SELECT Id, Name, GitHub_Username__c, Repo_Owner__c, Repo_Name__c,
                   Status__c, LastModifiedDate
            FROM GitHub_Connection__c
            ORDER BY LastModifiedDate DESC
        ];
    }

    // ═══════════════════════════════════════════════════════════
    // Delete connection
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static void deleteConnection(String connectionId) {
        try {
            delete new GitHub_Connection__c(Id = connectionId);
        } catch (Exception e) {
            throw new AuraHandledException('deleteConnection error: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Verify connection — test API call
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static Map<String, Object> verifyConnection(String connectionId) {
        try {
            GitHub_Connection__c conn = [
                SELECT Access_Token__c, Repo_Owner__c, Repo_Name__c
                FROM GitHub_Connection__c
                WHERE Id = :connectionId
                LIMIT 1
            ];

            HttpRequest req = new HttpRequest();
            req.setEndpoint('https://api.github.com/repos/' + conn.Repo_Owner__c + '/' + conn.Repo_Name__c);
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + conn.Access_Token__c);
            req.setHeader('Accept', 'application/vnd.github+json');
            req.setTimeout(TIMEOUT_MS);

            HttpResponse res = new Http().send(req);

            if (res.getStatusCode() == 200) {
                Map<String, Object> repoData = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                update new GitHub_Connection__c(Id = connectionId, Status__c = 'Connected');
                return new Map<String, Object>{
                    'success'  => true,
                    'repoName' => String.valueOf(repoData.get('full_name')),
                    'private'  => repoData.get('private'),
                    'message'  => 'Repository verified successfully'
                };
            } else {
                update new GitHub_Connection__c(Id = connectionId, Status__c = 'Disconnected');
                throw new AuraHandledException(
                    'Repo verification failed (' + res.getStatusCode() + '): ' + res.getBody()
                );
            }
        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('verifyConnection error: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // Verify repo access during connect
    // ═══════════════════════════════════════════════════════════
    private static void verifyRepoAccess(String accessToken, String repoOwner, String repoName) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint('https://api.github.com/repos/' + repoOwner + '/' + repoName);
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + accessToken);
        req.setHeader('Accept', 'application/vnd.github+json');
        req.setTimeout(TIMEOUT_MS);

        HttpResponse res = new Http().send(req);

        if (res.getStatusCode() == 404) {
            throw new AuraHandledException(
                'Repository "' + repoOwner + '/' + repoName + '" not found. Please check the owner and repo name.'
            );
        } else if (res.getStatusCode() == 401 || res.getStatusCode() == 403) {
            throw new AuraHandledException(
                'Access denied to repository "' + repoOwner + '/' + repoName + '". Make sure your GitHub account has access.'
            );
        } else if (res.getStatusCode() != 200) {
            throw new AuraHandledException(
                'Could not verify repository (' + res.getStatusCode() + '): ' + res.getBody()
            );
        }
    }
}