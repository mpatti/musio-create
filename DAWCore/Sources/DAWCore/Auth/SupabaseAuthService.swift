import Foundation
import Supabase
import AuthenticationServices

// MARK: - Auth User Model

public struct AuthUser: Codable, Sendable {
    public let id: String
    public let email: String?
    public let fullName: String?
    public let avatarURL: String?
    public let provider: AuthProvider
    public let createdAt: Date
    
    public init(id: String, email: String?, fullName: String?, avatarURL: String?, provider: AuthProvider, createdAt: Date) {
        self.id = id
        self.email = email
        self.fullName = fullName
        self.avatarURL = avatarURL
        self.provider = provider
        self.createdAt = createdAt
    }
}

public enum AuthProvider: String, Codable, Sendable {
    case email
    case apple
    case google
}

public enum AuthError: LocalizedError {
    case notConfigured
    case invalidCredentials
    case emailNotVerified
    case networkError(String)
    case unknown(String)
    
    public var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "Supabase is not configured. Please set up your project credentials."
        case .invalidCredentials:
            return "Invalid email or password."
        case .emailNotVerified:
            return "Please verify your email address."
        case .networkError(let message):
            return "Network error: \(message)"
        case .unknown(let message):
            return message
        }
    }
}

// MARK: - Supabase Auth Service

@MainActor
public final class SupabaseAuthService: ObservableObject {
    public static let shared = SupabaseAuthService()
    
    // MARK: - Published State
    
    @Published public private(set) var currentUser: AuthUser?
    @Published public private(set) var isAuthenticated: Bool = false
    @Published public private(set) var isLoading: Bool = false
    
    // MARK: - Supabase Client
    
    private var supabaseClient: SupabaseClient?
    
    // MARK: - Configuration Keys
    
    private static let supabaseURLKey = "com.musio.supabase.url"
    private static let supabaseAnonKeyKey = "com.musio.supabase.anonkey"
    
    // MARK: - Initialization
    
    private init() {
        loadConfiguration()
        Task {
            await checkSession()
        }
    }
    
    // MARK: - Configuration
    
    private func loadConfiguration() {
        guard let urlString = UserDefaults.standard.string(forKey: Self.supabaseURLKey),
              let anonKey = UserDefaults.standard.string(forKey: Self.supabaseAnonKeyKey),
              let url = URL(string: urlString) else {
            print("[SupabaseAuth] No configuration found. Please configure Supabase credentials.")
            return
        }
        
        supabaseClient = SupabaseClient(supabaseURL: url, supabaseKey: anonKey)
        print("[SupabaseAuth] Configured with URL: \(urlString)")
    }
    
    public func configure(url: String, anonKey: String) {
        UserDefaults.standard.set(url, forKey: Self.supabaseURLKey)
        UserDefaults.standard.set(anonKey, forKey: Self.supabaseAnonKeyKey)
        
        if let supabaseURL = URL(string: url) {
            supabaseClient = SupabaseClient(supabaseURL: supabaseURL, supabaseKey: anonKey)
            print("[SupabaseAuth] Configured successfully")
            
            Task {
                await checkSession()
            }
        }
    }
    
    public var isConfigured: Bool {
        supabaseClient != nil
    }
    
    // MARK: - Session Management
    
    private func checkSession() async {
        guard let client = supabaseClient else { return }
        
        do {
            let session = try await client.auth.session
            await updateUserFromSession(session)
        } catch {
            print("[SupabaseAuth] No existing session: \(error.localizedDescription)")
            currentUser = nil
            isAuthenticated = false
        }
    }
    
    private func updateUserFromSession(_ session: Session) async {
        let user = session.user
        
        // Extract provider from app_metadata
        let provider: AuthProvider
        if let providerString = user.appMetadata["provider"]?.value as? String {
            provider = AuthProvider(rawValue: providerString) ?? .email
        } else {
            provider = .email
        }
        
        // Extract name from user_metadata
        let fullName = user.userMetadata["full_name"]?.value as? String
            ?? user.userMetadata["name"]?.value as? String
        
        let avatarURL = user.userMetadata["avatar_url"]?.value as? String
            ?? user.userMetadata["picture"]?.value as? String
        
        currentUser = AuthUser(
            id: user.id.uuidString,
            email: user.email,
            fullName: fullName,
            avatarURL: avatarURL,
            provider: provider,
            createdAt: user.createdAt
        )
        isAuthenticated = true
        
        print("[SupabaseAuth] User signed in: \(user.email ?? "unknown")")
    }
    
    // MARK: - Email Authentication
    
    public func signUp(email: String, password: String, fullName: String?) async throws {
        guard let client = supabaseClient else {
            throw AuthError.notConfigured
        }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            var metadata: [String: AnyJSON] = [:]
            if let name = fullName {
                metadata["full_name"] = .string(name)
            }
            
            let response = try await client.auth.signUp(
                email: email,
                password: password,
                data: metadata
            )
            
            if let session = response.session {
                await updateUserFromSession(session)
            } else {
                // Email confirmation required
                print("[SupabaseAuth] Sign up successful. Please check email for verification.")
            }
        } catch {
            print("[SupabaseAuth] Sign up error: \(error)")
            throw AuthError.unknown(error.localizedDescription)
        }
    }
    
    public func signIn(email: String, password: String) async throws {
        guard let client = supabaseClient else {
            throw AuthError.notConfigured
        }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let session = try await client.auth.signIn(email: email, password: password)
            await updateUserFromSession(session)
        } catch {
            print("[SupabaseAuth] Sign in error: \(error)")
            throw AuthError.invalidCredentials
        }
    }
    
    public func resetPassword(email: String) async throws {
        guard let client = supabaseClient else {
            throw AuthError.notConfigured
        }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            try await client.auth.resetPasswordForEmail(email)
            print("[SupabaseAuth] Password reset email sent")
        } catch {
            print("[SupabaseAuth] Password reset error: \(error)")
            throw AuthError.unknown(error.localizedDescription)
        }
    }
    
    // MARK: - OAuth (Apple & Google)
    
    public func signInWithApple(idToken: String, nonce: String) async throws {
        guard let client = supabaseClient else {
            throw AuthError.notConfigured
        }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: .init(provider: .apple, idToken: idToken, nonce: nonce)
            )
            await updateUserFromSession(session)
        } catch {
            print("[SupabaseAuth] Apple sign in error: \(error)")
            throw AuthError.unknown(error.localizedDescription)
        }
    }
    
    public func signInWithGoogle(idToken: String, accessToken: String) async throws {
        guard let client = supabaseClient else {
            throw AuthError.notConfigured
        }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let session = try await client.auth.signInWithIdToken(
                credentials: .init(provider: .google, idToken: idToken, accessToken: accessToken)
            )
            await updateUserFromSession(session)
        } catch {
            print("[SupabaseAuth] Google sign in error: \(error)")
            throw AuthError.unknown(error.localizedDescription)
        }
    }
    
    // MARK: - Sign Out
    
    public func signOut() async throws {
        guard let client = supabaseClient else {
            throw AuthError.notConfigured
        }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            try await client.auth.signOut()
            currentUser = nil
            isAuthenticated = false
            print("[SupabaseAuth] User signed out")
        } catch {
            print("[SupabaseAuth] Sign out error: \(error)")
            throw AuthError.unknown(error.localizedDescription)
        }
    }
    
    // MARK: - Delete Account
    
    public func deleteAccount() async throws {
        guard let client = supabaseClient else {
            throw AuthError.notConfigured
        }
        
        // Note: Account deletion typically requires a server-side function
        // This is a placeholder - you'd need to set up a Supabase Edge Function
        print("[SupabaseAuth] Account deletion requested - implement server-side function")
        
        // For now, just sign out
        try await signOut()
    }
}

// MARK: - Apple Sign In Helper

public class AppleSignInHelper: NSObject, ASAuthorizationControllerDelegate {
    private var continuation: CheckedContinuation<(idToken: String, nonce: String), Error>?
    private var currentNonce: String?
    
    public func signIn() async throws -> (idToken: String, nonce: String) {
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            
            let nonce = randomNonceString()
            currentNonce = nonce
            
            let provider = ASAuthorizationAppleIDProvider()
            let request = provider.createRequest()
            request.requestedScopes = [.email, .fullName]
            request.nonce = sha256(nonce)
            
            let controller = ASAuthorizationController(authorizationRequests: [request])
            controller.delegate = self
            controller.performRequests()
        }
    }
    
    public func authorizationController(controller: ASAuthorizationController, didCompleteWithAuthorization authorization: ASAuthorization) {
        guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
              let identityTokenData = credential.identityToken,
              let idToken = String(data: identityTokenData, encoding: .utf8),
              let nonce = currentNonce else {
            continuation?.resume(throwing: AuthError.unknown("Failed to get Apple ID credentials"))
            return
        }
        
        continuation?.resume(returning: (idToken: idToken, nonce: nonce))
    }
    
    public func authorizationController(controller: ASAuthorizationController, didCompleteWithError error: Error) {
        continuation?.resume(throwing: error)
    }
    
    // MARK: - Nonce Generation
    
    private func randomNonceString(length: Int = 32) -> String {
        precondition(length > 0)
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, randomBytes.count, &randomBytes)
        if errorCode != errSecSuccess {
            fatalError("Unable to generate nonce")
        }
        
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        return String(randomBytes.map { charset[Int($0) % charset.count] })
    }
    
    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        inputData.withUnsafeBytes {
            _ = CC_SHA256($0.baseAddress, CC_LONG(inputData.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - CommonCrypto Import

import CommonCrypto
