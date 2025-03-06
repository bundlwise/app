import 'package:google_sign_in/google_sign_in.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:googleapis/gmail/v1.dart' as gmail;
import 'package:googleapis_auth/googleapis_auth.dart';
import 'package:http/http.dart' as http;

/// Service class that handles all Google Sign-In and Gmail operations
class GoogleAuthService {
  // Initialize Google Sign-In with required permissions (scopes)
  final GoogleSignIn _googleSignIn = GoogleSignIn(
    scopes: [
      'email', // Permission to get user's email
      'https://www.googleapis.com/auth/gmail.readonly', // Permission to read Gmail
      'https://www.googleapis.com/auth/gmail.labels', // Permission to access Gmail labels
    ],
    signInOption: SignInOption.standard, // Use standard Google Sign-In flow
  );

  // Keys for storing tokens in local storage
  static const String _tokenKey = 'google_access_token';
  static const String _tokenExpiryKey = 'google_token_expiry';

  /// Gets valid credentials, either from storage or by refreshing
  Future<AccessCredentials?> _getValidCredentials() async {
    try {
      // Step 1: Check if we have valid stored credentials
      final storedToken = await _getStoredToken();
      final storedExpiry = await _getStoredExpiry();

      // Step 2: If we have stored credentials, check if they're still valid
      if (storedToken != null && storedExpiry != null) {
        final expiry = DateTime.parse(storedExpiry);
        // Add 5-minute buffer to prevent edge cases
        if (expiry.isAfter(DateTime.now().add(const Duration(minutes: 5)))) {
          return AccessCredentials(
            AccessToken('Bearer', storedToken, expiry),
            null,
            _googleSignIn.scopes,
          );
        }
      }

      // Step 3: If no valid stored credentials, try to get new ones
      // First try silent sign-in, then fallback to current user
      final GoogleSignInAccount? account =
          _googleSignIn.currentUser ?? await _googleSignIn.signInSilently();
      if (account == null) return null;

      // Step 4: Get fresh authentication tokens
      final auth = await account.authentication;
      final accessToken = auth.accessToken;
      if (accessToken == null) return null;

      // Step 5: Store the new tokens
      final expiry = DateTime.now().toUtc().add(const Duration(hours: 1));
      await _storeToken(accessToken, expiry);

      return AccessCredentials(
        AccessToken('Bearer', accessToken, expiry),
        null,
        _googleSignIn.scopes,
      );
    } catch (e) {
      print('Error getting valid credentials: $e');
      return null;
    }
  }

  /// Public method to handle user sign-in
  Future<GoogleSignInAccount?> signIn() async {
    try {
      print('GoogleAuthService: Starting sign-in process...'); // Debug log

      // Check if user is already signed in
      if (_googleSignIn.currentUser != null) {
        print(
            'GoogleAuthService: User already signed in, returning current user'); // Debug log
        return _googleSignIn.currentUser;
      }

      // Trigger the Google Sign-In flow
      final GoogleSignInAccount? googleUser = await _googleSignIn.signIn();
      print(
          'GoogleAuthService: Sign-in result - ${googleUser?.email}'); // Debug log

      if (googleUser != null) {
        try {
          // Get authentication details
          final auth = await googleUser.authentication;
          print('GoogleAuthService: Got authentication token'); // Debug log

          if (auth.accessToken != null) {
            final expiry = DateTime.now().toUtc().add(const Duration(hours: 1));
            await _storeToken(auth.accessToken!, expiry);
            print(
                'GoogleAuthService: Stored authentication token'); // Debug log
          }
        } catch (authError) {
          print(
              'GoogleAuthService: Error getting authentication: $authError'); // Debug log
          // Even if token storage fails, we still want to return the user
        }
      } else {
        print(
            'GoogleAuthService: Sign-in was cancelled or failed'); // Debug log
      }

      return googleUser;
    } catch (e) {
      print('GoogleAuthService: Error in sign-in process: $e'); // Debug log
      rethrow; // Rethrow the error to be handled by the UI
    }
  }

  /// Fetches the last 10 email subjects from Gmail
  Future<List<String>> getEmails() async {
    try {
      print('GoogleAuthService: Starting to fetch emails...'); // Debug log

      // Step 1: Get valid credentials
      final credentials = await _getValidCredentials();
      if (credentials == null) {
        print('GoogleAuthService: No valid credentials found'); // Debug log
        throw Exception('Not authenticated');
      }

      // Step 2: Create authenticated HTTP client
      final client = http.Client();
      final authedClient = authenticatedClient(client, credentials);

      try {
        // Step 3: Initialize Gmail API
        final gmailApi = gmail.GmailApi(authedClient);
        print('GoogleAuthService: Gmail API initialized'); // Debug log

        // Step 4: Get list of messages
        final response = await gmailApi.users.messages.list('me');
        final messages = response.messages ?? [];
        print(
            'GoogleAuthService: Found ${messages.length} messages'); // Debug log

        // Step 5: Get subject for each message
        List<String> emails = [];
        for (var message in messages.take(10)) {
          final detail = await gmailApi.users.messages.get('me', message.id!);
          final subject = detail.payload?.headers
              ?.firstWhere(
                (header) => header.name == 'Subject',
                orElse: () => gmail.MessagePartHeader(),
              )
              .value;
          if (subject != null) {
            emails.add(subject);
          }
        }

        print(
            'GoogleAuthService: Successfully fetched ${emails.length} email subjects'); // Debug log
        return emails;
      } finally {
        client.close();
      }
    } catch (e) {
      print('GoogleAuthService: Error getting emails: $e'); // Debug log
      if (e.toString().contains('401') || e.toString().contains('403')) {
        await _clearStoredTokens();
        print(
            'GoogleAuthService: Cleared stored tokens due to auth error'); // Debug log
      }
      return [];
    }
  }

  /// Signs out the user and clears stored tokens
  Future<void> signOut() async {
    await _clearStoredTokens();
    await _googleSignIn.signOut();
  }

  // Local storage methods for token management
  Future<void> _storeToken(String token, DateTime expiry) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_tokenKey, token);
    await prefs.setString(_tokenExpiryKey, expiry.toIso8601String());
  }

  Future<String?> _getStoredToken() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenKey);
  }

  Future<String?> _getStoredExpiry() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getString(_tokenExpiryKey);
  }

  Future<void> _clearStoredTokens() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_tokenKey);
    await prefs.remove(_tokenExpiryKey);
  }
}
