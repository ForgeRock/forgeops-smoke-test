import 'package:dio/dio.dart';
import 'dart:convert';
import 'dart:math';
import 'package:forgeops_smoke_test/forgerock_smoke_test.dart';
import 'package:forgeops_smoke_test/rest/rest_client.dart';

final _random = Random();

// Make REST calls to ForgeRock AM.
class AMRest  extends RESTClient {
  final String _amUrl;
  String _amCookie;
  final String _adminPassword;

  AMRest(TestConfiguration t) :
        _adminPassword = t.amAdminPassword,
        _amUrl = '${t.fqdn}/am',
        super(t);

  Future<String> authenticateAsAdmin() async {
    var headers = {
      'X-OpenAM-Username': 'amadmin',
      'X-OpenAM-Password': _adminPassword,
      'Accept-API-Version': 'resource=2.1, protocol=1.0'
    };

    var r = await dio.post(
        '$_amUrl/json/authenticate?realm=/&authIndexType=service&authIndexValue=ldapService',
        options: RequestOptions(
            headers: headers, contentType: Headers.jsonContentType));
    _amCookie = r.data['tokenId'];
    return _amCookie;
  }

  // regex used to extract code= from the location header.
  final _codeRegex = RegExp(r'(?<=code=)(.+?)(?=&)');

  // Perform the auth code oauth2 flow to get an access token
  // this is done as the user amadmin - so we get an access
  // token that can be used for IDM.
  Future<String> authCodeFlow(
      {String redirectUrl, String client_id, List<String> scopes}) async {
    if (_amCookie == null) {
      await authenticateAsAdmin();
    }
    var headers = {'accept-api-version': 'resource=2.1'};
    var params = {
      'redirect_uri': redirectUrl,
      'client_id': client_id,
      'response_type': 'code',
      'scope': 'openid', // todo: fix scopes
    };
    var options = Options(
        headers: headers,
        contentType: Headers.formUrlEncodedContentType,
        followRedirects: false,
        validateStatus: (status) => status < 500);
    var r = await dio.post('$_amUrl/oauth2/authorize',
        options: options,
        queryParameters: params,
        data: {'decision': 'Allow', 'csrf': _amCookie});
    var loc_header = r.headers.value('location');
    var auth_code = _codeRegex.firstMatch(loc_header).group(0);

    var data = {
      'grant_type': 'authorization_code',
      'code': auth_code,
      'redirect_uri': redirectUrl,
      'client_id': client_id
    };

    options = Options(
        headers: {
          'Accept-API-Version': 'resource=2.0, protocol=1.0',
        },
        contentType: Headers.formUrlEncodedContentType,
        followRedirects: false,
        validateStatus: (status) => status < 500);

    var r2 = await dio.post('$_amUrl/oauth2/access_token',
        data: data, options: options);
    return r2.data['access_token'];
  }

  /// Client Credential flow to get an oauth2 token
  Future<String> getOAuth2Token(String clientId, String clientPassword) async {
    var auth =
        'Basic ' + base64Encode(utf8.encode('$clientId:$clientPassword'));

    var options = Options(headers: {
      'Authorization': auth,
    }, contentType: Headers.formUrlEncodedContentType);

    var r = await dio.post('$_amUrl/oauth2/access_token',
        data: {'grant_type': 'client_credentials'}, options: options);

    return r.data['access_token'];
  }

  Future<String> getOAuth2TokenResourceOwnerFlow(
      String clientId, String clientPassword,
      [String user = 'amadmin', String password]) async {
    var auth =
        'Basic ' + base64Encode(utf8.encode('$clientId:$clientPassword'));

    var options = Options(headers: {
      'Authorization': auth,
    }, contentType: Headers.formUrlEncodedContentType);

    var r = await dio.post('$_amUrl/oauth2/access_token',
        data: {'grant_type': 'client_credentials'}, options: options);

    return r.data['access_token'];
  }

  // Register an oauth2 client. [token] is an oauth2 access token
  // that has the scope dynamic_client_registration assigned.
  // https://backstage.forgerock.com/docs/am/6.5/oauth2-guide/#register-oauth2-client-dynamic-access-token-example
  // https://openid.net/specs/openid-connect-core-1_0-17.html#codeExample
  Future<Map<String, Object>> registerOAuthClient(String token) async {
    var options = Options(headers: {'Authorization': 'Bearer $token'});
    var r = await dio.post('$_amUrl/oauth2/register',
        data: {
          'redirect_uris': ['https://fake.com'],
          'client name': 'Test Client',
          'client_uri': 'https://fake.com',
          'scopes': ['profile', 'openid'],
          'response_types': ['code', 'id_token', 'token'],
        },
        options: options);
    return r.data as Map<String, Object>;
  }

  // Self register a test use.
  Future<Map> selfRegisterUser() async {
    var regURl = '$_amUrl/json/realms/root/authenticate';
    var q = {'authIndexType': 'service', 'authIndexValue': 'Registration'};
    var options = RequestOptions(
        headers: {'accept-api-version': 'protocol=1.0,resource=2.1'});

    // we dont want to reuse saved cookies - so create a new request
    var _d = Dio();
    if (testConfig.debug) {
      _d.interceptors.add(LogInterceptor());
    }

    var r = await _d.post(regURl, queryParameters: q, options: options);
    check200(r);

    var copyMap = jsonDecode(jsonEncode(r.data))
        as Map<String, Object>; // kludgy, but works
    var callbacks = copyMap['callbacks'] as List;

    var rand = _random.nextInt(1000000);
    var user = 'tuser$rand';
    // This is quite kludgy as it depends on the order of the callbacks
    // todo: Eventually we should check for order
    callbacks[0]['input'][0]['value'] = user;
    callbacks[1]['input'][0]['value'] = 'Yogi';
    callbacks[2]['input'][0]['value'] = 'Bear';
    callbacks[3]['input'][0]['value'] = '$user@example.com';
    callbacks[4]['input'][0]['value'] = false;
    callbacks[5]['input'][0]['value'] = false;
    callbacks[6]['input'][0]['value'] = TestConfiguration.TEST_PASSWORD;
    callbacks[7]['input'][0]['value'] = 'What\'s your favorite color?';
    callbacks[7]['input'][1]['value'] = 'green';
    callbacks[8]['input'][0]['value'] = 'Who was your first employer?';
    callbacks[8]['input'][1]['value'] = 'forgerock';
    callbacks[9]['input'][0]['value'] = true;

    r = await _d.post(regURl,
        queryParameters: q, options: options, data: copyMap);
    check200(r);
    r.data['userId'] = user; // we add the user id in case future tests need it
    return r.data as Map;
  }
}
