public without sharing class GitHubManagerCtrl {

    // ═══════════════════════════════════════════════════════════
    // CONSTANTS
    // ═══════════════════════════════════════════════════════════
    private static final Integer TIMEOUT_MS = 120000;
    private static final String GITHUB_API_BASE = 'https://api.github.com';
    private static final String GITHUB_OAUTH_BASE = 'https://github.com/login/oauth';
    private static final String HEADER_ACCEPT = 'application/vnd.github+json';
    private static final String STATUS_CONNECTED = 'Connected';
    private static final String STATUS_DISCONNECTED = 'Disconnected';

    // ═══════════════════════════════════════════════════════════
    // RESPONSE WRAPPER
    // ═══════════════════════════════════════════════════════════
    public class ApiResponse {
        @AuraEnabled public Boolean success;
        @AuraEnabled public String message;
        @AuraEnabled public String username;
        @AuraEnabled public String connectionId;
        @AuraEnabled public String repoName;
        @AuraEnabled public Boolean isPrivate;
    }

    // ═══════════════════════════════════════════════════════════
    // HELPER METHOD FOR LWC EXCEPTIONS
    // ═══════════════════════════════════════════════════════════
    private static AuraHandledException createException(String msg) {
        AuraHandledException ex = new AuraHandledException(msg);
        ex.setMessage(msg);
        return ex;
    }

    // ═══════════════════════════════════════════════════════════
    // FETCH GITHUB CONFIG
    // ═══════════════════════════════════════════════════════════
    private static OAuth_Config__mdt getGitHubConfig() {
        List<OAuth_Config__mdt> configs = [
            SELECT Client_Id__c, Client_Secret__c, Callback_Url__c
            FROM OAuth_Config__mdt
            WHERE App_Type__c = 'GitHub'
            LIMIT 1
        ];

        if (configs.isEmpty()) {
            throw createException('No GitHub OAuth configuration found.');
        }

        return configs[0];
    }

    // ═══════════════════════════════════════════════════════════
    // COMMON REQUEST BUILDER
    // ═══════════════════════════════════════════════════════════
    private static HttpRequest createRequest(String endpoint, String method, String accessToken) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(endpoint);
        req.setMethod(method);
        req.setTimeout(TIMEOUT_MS);
        req.setHeader('Accept', HEADER_ACCEPT);

        if (!String.isBlank(accessToken)) {
            req.setHeader('Authorization', 'Bearer ' + accessToken);
        }

        return req;
    }

    // ═══════════════════════════════════════════════════════════
    // STEP 1 — GET AUTHORIZATION URL
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static String getAuthorizationUrl(String stateToken) {
        try {
            OAuth_Config__mdt config = getGitHubConfig();

            String authUrl = GITHUB_OAUTH_BASE + '/authorize'
                + '?client_id=' + EncodingUtil.urlEncode(config.Client_Id__c, 'UTF-8')
                + '&redirect_uri=' + EncodingUtil.urlEncode(config.Callback_Url__c, 'UTF-8')
                + '&scope=' + EncodingUtil.urlEncode('repo user', 'UTF-8')
                + '&state=' + EncodingUtil.urlEncode(stateToken, 'UTF-8');

            return authUrl;

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createException('Authorization URL Error: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // STEP 2 — EXCHANGE CODE & SAVE
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static ApiResponse exchangeCodeAndSave(String authCode, String connectionName, String repoOwner, String repoName) {
        try {
            OAuth_Config__mdt config = getGitHubConfig();

            HttpRequest req = createRequest(GITHUB_OAUTH_BASE + '/access_token', 'POST', null);
            req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            req.setHeader('Accept', 'application/json');

            req.setBody(
                'client_id=' + EncodingUtil.urlEncode(config.Client_Id__c, 'UTF-8')
                + '&client_secret=' + EncodingUtil.urlEncode(config.Client_Secret__c, 'UTF-8')
                + '&code=' + EncodingUtil.urlEncode(authCode, 'UTF-8')
                + '&redirect_uri=' + EncodingUtil.urlEncode(config.Callback_Url__c, 'UTF-8')
            );

            HttpResponse res = new Http().send(req);

            if (res.getStatusCode() != 200) {
                throw createException('Token exchange failed: ' + res.getBody());
            }

            Map<String, Object> tokenData = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String accessToken = String.valueOf(tokenData.get('access_token'));

            if (String.isBlank(accessToken) || accessToken == 'null') {
                throw createException('No access token received.');
            }

            // Fetch GitHub username  
            String githubUsername = fetchGitHubUsername(accessToken);
             
             if (!githubUsername.equalsIgnoreCase(repoOwner)) {
                throw createException(
                   'You are logged in as "' + githubUsername + '" but Repo Owner is "' + repoOwner + '". Please login with the correct GitHub account.'
                     );
           }

            // Verify repository access
            verifyRepoAccess(accessToken, repoOwner, repoName);

            // Check duplicate repo
            checkDuplicateRepo(connectionName, repoOwner, repoName);

            // Save connection
            GitHub_Connection__c conn = upsertConnection(connectionName, githubUsername, accessToken, repoOwner, repoName);

            ApiResponse response = new ApiResponse();
            response.success = true;
            response.message = 'Connected successfully';
            response.username = githubUsername;
            response.connectionId = conn.Id;

            return response;

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createException('Exchange Error: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // FETCH GITHUB USERNAME
    // ═══════════════════════════════════════════════════════════
    private static String fetchGitHubUsername(String accessToken) {
        try {
            HttpRequest req = createRequest(GITHUB_API_BASE + '/user', 'GET', accessToken);
            HttpResponse res = new Http().send(req);

            if (res.getStatusCode() != 200) {
                throw createException('Failed to fetch GitHub user.');
            }

            Map<String, Object> data = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            return String.valueOf(data.get('login'));

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createException('GitHub user fetch error: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // VERIFY REPOSITORY ACCESS
    // ═══════════════════════════════════════════════════════════
    private static HttpResponse getRepoResponse(String accessToken, String repoOwner, String repoName) {
        HttpRequest req = createRequest(GITHUB_API_BASE + '/repos/' + repoOwner + '/' + repoName, 'GET', accessToken);
        return new Http().send(req);
    }

    private static void verifyRepoAccess(String accessToken, String repoOwner, String repoName) {
        HttpResponse res = getRepoResponse(accessToken, repoOwner, repoName);
        Integer statusCode = res.getStatusCode();

        if (statusCode == 404) {
            throw createException('Repository not found.');
        } else if (statusCode == 401 || statusCode == 403) {
            throw createException('Access denied to repository.');
        } else if (statusCode != 200) {
            throw createException('Repository verification failed: ' + res.getBody());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // CHECK DUPLICATE REPOSITORY
    // ═══════════════════════════════════════════════════════════
    private static void checkDuplicateRepo(String connectionName, String repoOwner, String repoName) {
        List<GitHub_Connection__c> existing = [
            SELECT Id, Name
            FROM GitHub_Connection__c
            WHERE Repo_Owner__c = :repoOwner
            AND Repo_Name__c = :repoName
            AND Name != :connectionName
            LIMIT 1
        ];

        if (!existing.isEmpty()) {
            throw createException('Repository already connected as "' + existing[0].Name + '".');
        }
    }

    // ═══════════════════════════════════════════════════════════
    // UPSERT CONNECTION
    // ═══════════════════════════════════════════════════════════
    private static GitHub_Connection__c upsertConnection(String connectionName, String githubUsername, String accessToken, String repoOwner, String repoName) {
        List<GitHub_Connection__c> existing = [
            SELECT Id
            FROM GitHub_Connection__c
            WHERE Name = :connectionName
            LIMIT 1
        ];

        GitHub_Connection__c conn = existing.isEmpty() ? new GitHub_Connection__c() : existing[0];
        conn.Name = connectionName;
        conn.GitHub_Username__c = githubUsername;
        conn.Access_Token__c = accessToken;
        conn.Repo_Owner__c = repoOwner;
        conn.Repo_Name__c = repoName;
        conn.Status__c = STATUS_CONNECTED;
        conn.Connected_By__c = UserInfo.getUserId();

        upsert conn;
        return conn;
    }

    // ═══════════════════════════════════════════════════════════
    // GET SAVED CONNECTIONS
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled(cacheable=false)
    public static List<GitHub_Connection__c> getSavedConnections() {
        return [
            SELECT Id, Name, GitHub_Username__c, Repo_Owner__c, Repo_Name__c, Status__c, LastModifiedDate
            FROM GitHub_Connection__c
            WITH SECURITY_ENFORCED
            ORDER BY LastModifiedDate DESC
        ];
    }

    // ═══════════════════════════════════════════════════════════
    // DELETE CONNECTION
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static void deleteConnection(String connectionId) {
        try {
            delete new GitHub_Connection__c(Id = connectionId);
        } catch (Exception e) {
            throw createException('Delete Error: ' + e.getMessage());
        }
    }

    // ═══════════════════════════════════════════════════════════
    // VERIFY CONNECTION
    // ═══════════════════════════════════════════════════════════
    @AuraEnabled
    public static ApiResponse verifyConnection(String connectionId) {
        try {
            GitHub_Connection__c conn = [
                SELECT Access_Token__c, Repo_Owner__c, Repo_Name__c
                FROM GitHub_Connection__c
                WHERE Id = :connectionId
                LIMIT 1
            ];

            HttpResponse res = getRepoResponse(conn.Access_Token__c, conn.Repo_Owner__c, conn.Repo_Name__c);
            ApiResponse response = new ApiResponse();

            if (res.getStatusCode() == 200) {
                Map<String, Object> repoData = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());

                update new GitHub_Connection__c(
                    Id = connectionId,
                    Status__c = STATUS_CONNECTED
                );

                response.success = true;
                response.repoName = String.valueOf(repoData.get('full_name'));
                response.isPrivate = (Boolean) repoData.get('private');
                response.message = 'Repository verified successfully';

            } else {
                update new GitHub_Connection__c(
                    Id = connectionId,
                    Status__c = STATUS_DISCONNECTED
                );
                throw createException('Repository verification failed.');
            }

            return response;

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw createException('Verification Error: ' + e.getMessage());
        }
    }
}