public without sharing class EnvironmentManagerV2Ctrl {

    private static final Integer TIMEOUT_MS = 120000;

    
    private static OAuth_Config__mdt getDefaultConfig() {
        return [
            SELECT Client_Id__c, Client_Secret__c, Callback_Url__c
            FROM OAuth_Config__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
    }

    @AuraEnabled
    public static String getAuthorizationUrl(String orgType, String stateToken) {
        try {
            OAuth_Config__mdt config = getDefaultConfig();

            String baseUrl = (orgType == 'sandbox')
                ? 'https://test.salesforce.com'
                : 'https://login.salesforce.com';

            String url = baseUrl + '/services/oauth2/authorize'
                + '?response_type=code'
                + '&client_id='    + EncodingUtil.urlEncode(config.Client_Id__c,    'UTF-8')
                + '&redirect_uri=' + EncodingUtil.urlEncode(config.Callback_Url__c, 'UTF-8')
                + '&scope='        + EncodingUtil.urlEncode('api refresh_token',    'UTF-8')
                + '&state='        + EncodingUtil.urlEncode(stateToken,             'UTF-8')
                + '&prompt=login%20consent';

            return url;
        } catch (Exception e) {
            throw new AuraHandledException('getAuthorizationUrl error: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static Map<String, Object> exchangeCodeAndSave(
        String authCode,
        String orgType,
        String environmentName
    ) {
        try {
            OAuth_Config__mdt config = getDefaultConfig();

            String tokenEndpoint = (orgType == 'sandbox')
                ? 'https://test.salesforce.com/services/oauth2/token'
                : 'https://login.salesforce.com/services/oauth2/token';

            HttpRequest req = new HttpRequest();
            req.setEndpoint(tokenEndpoint);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            req.setTimeout(TIMEOUT_MS);
            req.setBody(
                'grant_type=authorization_code'
                + '&code='          + EncodingUtil.urlEncode(authCode,               'UTF-8')
                + '&client_id='     + EncodingUtil.urlEncode(config.Client_Id__c,    'UTF-8')
                + '&client_secret=' + EncodingUtil.urlEncode(config.Client_Secret__c,'UTF-8')
                + '&redirect_uri='  + EncodingUtil.urlEncode(config.Callback_Url__c, 'UTF-8')
            );

            HttpResponse res = new Http().send(req);

            if (res.getStatusCode() != 200) {
                throw new AuraHandledException(
                    'Token exchange failed (' + res.getStatusCode() + '): ' + res.getBody()
                );
            }

            Map<String, Object> tokenData   = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            String              accessToken  = String.valueOf(tokenData.get('access_token'));
            String              refreshToken = String.valueOf(tokenData.get('refresh_token'));
            String              instanceUrl  = String.valueOf(tokenData.get('instance_url'));

            String orgName = fetchOrgName(accessToken, instanceUrl);

            Environment__c env = upsertEnvironmentRecord(
                environmentName, orgName, orgType, refreshToken, instanceUrl
            );

            return new Map<String, Object>{
                'success'       => true,
                'orgName'       => orgName,
                'instanceUrl'   => instanceUrl,
                'environmentId' => env.Id,
                'message'       => 'Connected successfully: ' + orgName
            };

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('exchangeCodeAndSave error: ' + e.getMessage());
        }
    }

    private static String fetchOrgName(String accessToken, String instanceUrl) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(instanceUrl + '/services/oauth2/userinfo');
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + accessToken);
            req.setTimeout(TIMEOUT_MS);

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() == 200) {
                Map<String, Object> info = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                if (info.containsKey('organization') && info.get('organization') != null) {
                    Map<String, Object> org = (Map<String, Object>) info.get('organization');
                    if (org.containsKey('name')) return String.valueOf(org.get('name'));
                }
                return fetchOrgNameFromApi(accessToken, instanceUrl);
            }
            return 'Unknown Org';
        } catch (Exception e) {
            return 'Unknown Org';
        }
    }

    private static String fetchOrgNameFromApi(String accessToken, String instanceUrl) {
        try {
            HttpRequest req = new HttpRequest();
            req.setEndpoint(instanceUrl + '/services/data/v64.0/query?q='
                + EncodingUtil.urlEncode('SELECT Name FROM Organization LIMIT 1', 'UTF-8'));
            req.setMethod('GET');
            req.setHeader('Authorization', 'Bearer ' + accessToken);
            req.setHeader('Content-Type', 'application/json');
            req.setTimeout(TIMEOUT_MS);

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() == 200) {
                Map<String, Object> parsed  = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
                List<Object>        records = (List<Object>) parsed.get('records');
                if (records != null && !records.isEmpty()) {
                    return String.valueOf(((Map<String, Object>) records[0]).get('Name'));
                }
            }
            return 'Unknown Org';
        } catch (Exception e) {
            return 'Unknown Org';
        }
    }

    private static Environment__c upsertEnvironmentRecord(
        String environmentName,
        String orgName,
        String orgType,
        String refreshToken,
        String instanceUrl
    ) {
        List<Environment__c> existing = [
            SELECT Id FROM Environment__c
            WHERE Name = :environmentName
            LIMIT 1
        ];

        Environment__c env = existing.isEmpty() ? new Environment__c() : existing[0];
        env.Name                 = environmentName;
        env.Org_Name__c          = orgName;
        env.Org_Type__c          = (orgType == 'sandbox') ? 'Sandbox' : 'Production';
        env.Refresh_Token__c     = refreshToken;
        env.Connection_Status__c = 'Connected';

        upsert env;
        return env;
    }

    @AuraEnabled(cacheable=false)
    public static List<Environment__c> getSavedEnvironments() {
        return [
            SELECT Id, Name, Org_Name__c, Org_Type__c, Connection_Status__c, LastModifiedDate
            FROM Environment__c
            ORDER BY LastModifiedDate DESC
        ];
    }

    @AuraEnabled
    public static void deleteEnvironment(String environmentId) {
        try {
            delete new Environment__c(Id = environmentId);
        } catch (Exception e) {
            throw new AuraHandledException('deleteEnvironment error: ' + e.getMessage());
        }
    }

    @AuraEnabled
    public static Map<String, String> refreshAccessToken(String environmentId) {
        try {
            Environment__c env = [
                SELECT Name, Org_Type__c, Refresh_Token__c
                FROM Environment__c
                WHERE Id = :environmentId
                LIMIT 1
            ];

            if (String.isBlank(env.Refresh_Token__c)) {
                throw new AuraHandledException('No refresh token stored. Please reconnect.');
            }

            OAuth_Config__mdt config = getDefaultConfig();

            String tokenEndpoint = (env.Org_Type__c == 'Sandbox')
                ? 'https://test.salesforce.com/services/oauth2/token'
                : 'https://login.salesforce.com/services/oauth2/token';

            HttpRequest req = new HttpRequest();
            req.setEndpoint(tokenEndpoint);
            req.setMethod('POST');
            req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            req.setTimeout(TIMEOUT_MS);
            req.setBody(
                'grant_type=refresh_token'
                + '&client_id='     + EncodingUtil.urlEncode(config.Client_Id__c,     'UTF-8')
                + '&client_secret=' + EncodingUtil.urlEncode(config.Client_Secret__c,  'UTF-8')
                + '&refresh_token=' + EncodingUtil.urlEncode(env.Refresh_Token__c,    'UTF-8')
            );

            HttpResponse res = new Http().send(req);
            if (res.getStatusCode() != 200) {
                env.Connection_Status__c = 'Disconnected';
                update env;
                throw new AuraHandledException('Token refresh failed. Please reconnect.');
            }

            Map<String, Object> tokenData = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
            return new Map<String, String>{
                'accessToken' => String.valueOf(tokenData.get('access_token')),
                'instanceUrl' => String.valueOf(tokenData.get('instance_url'))
            };

        } catch (AuraHandledException e) {
            throw e;
        } catch (Exception e) {
            throw new AuraHandledException('refreshAccessToken error: ' + e.getMessage());
        }
    }
}