@RestResource(urlMapping='/OAuthCallback')
global without sharing class OAuthCallbackCtrl {

    private static final Integer TIMEOUT_MS = 120000;

    @HttpPost
    global static void doPost() {
        RestRequest  req = RestContext.request;
        RestResponse res = RestContext.response;
        res.addHeader('Content-Type', 'application/json');

        try {
            Map<String,Object> body = (Map<String,Object>) JSON.deserializeUntyped(req.requestBody.toString());
            String code            = String.valueOf(body.get('code'));
            String environmentName = String.valueOf(body.get('environmentName'));
            String orgType         = String.valueOf(body.get('orgType'));

            // ── Step 1: Fast duplicate check (no HTTP, sirf DB) ──
            List<Environment__c> alreadyConnected = [
                SELECT Id, Name FROM Environment__c
                WHERE Name = :environmentName
                AND Connection_Status__c = 'Connected'
                LIMIT 1
            ];
            if (!alreadyConnected.isEmpty()) {
                res.statusCode   = 200;
                res.responseBody = Blob.valueOf(JSON.serialize(new Map<String,Object>{
                    'success' => false,
                    'message' => '"' + environmentName + '" is already connected. Please delete it first to reconnect.'
                }));
                return;
            }

            // ── Step 2: Token exchange ──
            OAuth_Config__mdt config = getConfig(environmentName);
            String tokenEndpoint = (orgType == 'sandbox')
                ? 'https://test.salesforce.com/services/oauth2/token'
                : 'https://login.salesforce.com/services/oauth2/token';

            HttpRequest tokenReq = new HttpRequest();
            tokenReq.setEndpoint(tokenEndpoint);
            tokenReq.setMethod('POST');
            tokenReq.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            tokenReq.setTimeout(TIMEOUT_MS);
            tokenReq.setBody(
                'grant_type=authorization_code'
                + '&code='          + EncodingUtil.urlEncode(code,                    'UTF-8')
                + '&client_id='     + EncodingUtil.urlEncode(config.Client_Id__c,     'UTF-8')
                + '&client_secret=' + EncodingUtil.urlEncode(config.Client_Secret__c, 'UTF-8')
                + '&redirect_uri='  + EncodingUtil.urlEncode(config.Callback_Url__c,  'UTF-8')
            );

            HttpResponse tokenRes = new Http().send(tokenReq);
            if (tokenRes.getStatusCode() != 200) {
                res.statusCode   = 200;
                res.responseBody = Blob.valueOf(JSON.serialize(new Map<String,Object>{
                    'success' => false,
                    'message' => 'Token exchange failed (' + tokenRes.getStatusCode() + '): ' + tokenRes.getBody()
                }));
                return;
            }

            Map<String,Object> tokenData = (Map<String,Object>) JSON.deserializeUntyped(tokenRes.getBody());
            String accessToken  = String.valueOf(tokenData.get('access_token'));
            String refreshToken = String.valueOf(tokenData.get('refresh_token'));
            String instanceUrl  = String.valueOf(tokenData.get('instance_url'));

            // ── Step 3: Org name fetch ──
            String orgName = fetchOrgName(accessToken, instanceUrl);

            // ── Step 4: Same org already connected check ──
            if (String.isNotBlank(orgName) && orgName != 'Unknown Org') {
                List<Environment__c> sameOrg = [
                    SELECT Id, Name FROM Environment__c
                    WHERE Org_Name__c = :orgName
                    AND Name         != :environmentName
                    AND Connection_Status__c = 'Connected'
                    LIMIT 1
                ];
                if (!sameOrg.isEmpty()) {
                    res.statusCode   = 200;
                    res.responseBody = Blob.valueOf(JSON.serialize(new Map<String,Object>{
                        'success' => false,
                        'message' => 'This org is already connected as "' + sameOrg[0].Name + '". Please delete that entry first.'
                    }));
                    return;
                }
            }

            // ── Step 5: Save / upsert ──
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

            res.statusCode   = 200;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String,Object>{
                'success' => true,
                'message' => 'Connected to: ' + orgName
            }));

        } catch (Exception e) {
            res.statusCode   = 200;
            res.responseBody = Blob.valueOf(JSON.serialize(new Map<String,Object>{
                'success' => false,
                'message' => 'Error: ' + e.getMessage()
            }));
        }
    }

    private static OAuth_Config__mdt getConfig(String environmentName) {
        String safeName = environmentName != null
            ? environmentName.replaceAll('[^a-zA-Z0-9_]', '_')
            : 'Default';
        List<OAuth_Config__mdt> specific = [
            SELECT Client_Id__c, Client_Secret__c, Callback_Url__c
            FROM OAuth_Config__mdt
            WHERE DeveloperName = :safeName
            LIMIT 1
        ];
        if (!specific.isEmpty()) return specific[0];
        return [
            SELECT Client_Id__c, Client_Secret__c, Callback_Url__c
            FROM OAuth_Config__mdt
            WHERE DeveloperName = 'Default'
            LIMIT 1
        ];
    }

    private static String fetchOrgName(String accessToken, String instanceUrl) {
        try {
            HttpRequest r = new HttpRequest();
            r.setEndpoint(instanceUrl + '/services/oauth2/userinfo');
            r.setMethod('GET');
            r.setHeader('Authorization', 'Bearer ' + accessToken);
            r.setTimeout(30000);
            HttpResponse res = new Http().send(r);
            if (res.getStatusCode() == 200) {
                Map<String,Object> info = (Map<String,Object>) JSON.deserializeUntyped(res.getBody());
                if (info.containsKey('organization') && info.get('organization') != null) {
                    Map<String,Object> org = (Map<String,Object>) info.get('organization');
                    if (org.containsKey('name')) return String.valueOf(org.get('name'));
                }
            }
            // fallback: SOQL
            HttpRequest r2 = new HttpRequest();
            r2.setEndpoint(instanceUrl + '/services/data/v64.0/query?q='
                + EncodingUtil.urlEncode('SELECT Name FROM Organization LIMIT 1', 'UTF-8'));
            r2.setMethod('GET');
            r2.setHeader('Authorization', 'Bearer ' + accessToken);
            r2.setTimeout(30000);
            HttpResponse res2 = new Http().send(r2);
            if (res2.getStatusCode() == 200) {
                Map<String,Object> parsed  = (Map<String,Object>) JSON.deserializeUntyped(res2.getBody());
                List<Object>       records = (List<Object>) parsed.get('records');
                if (records != null && !records.isEmpty()) {
                    return String.valueOf(((Map<String,Object>) records[0]).get('Name'));
                }
            }
        } catch (Exception e) {}
        return 'Unknown Org';
    }
}