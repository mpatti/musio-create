import SwiftUI
#if canImport(AppKit)
import AppKit
#endif
#if canImport(AuthenticationServices)
import AuthenticationServices
#endif
import DAWCore

// MARK: - Authentication View

public struct AuthenticationView: View {
    @ObservedObject private var authService = SupabaseAuthService.shared
    
    @State private var mode: AuthMode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var confirmPassword = ""
    @State private var fullName = ""
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @State private var showingForgotPassword = false
    
    @Environment(\.dismiss) private var dismiss
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            // Close button
            HStack {
                Spacer()
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .focusable(false)
                .padding(12)
            }
            
            // Header
            header
            
            Spacer().frame(height: 20)
            
            // Content
            VStack(spacing: 20) {
                // Social sign-in buttons
                socialButtons
                
                // Divider
                HStack {
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 1)
                    Text("or")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 8)
                    Rectangle()
                        .fill(Color.gray.opacity(0.3))
                        .frame(height: 1)
                }
                .padding(.horizontal, 24)
                
                // Email form
                emailForm
                
                // Error/Success messages
                messages
                
                // Submit button
                submitButton
                
                // Toggle mode
                toggleModeButton
            }
            
            Spacer()
        }
        .frame(width: 380, height: mode == .signUp ? 580 : 520)
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingForgotPassword) {
            ForgotPasswordView()
        }
    }
    
    // MARK: - Header
    
    private var header: some View {
        VStack(spacing: 8) {
            MusioLogo()
                .frame(width: 60, height: 50)
            
            Text("Musio Create")
                .font(.title2)
                .fontWeight(.bold)
            
            Text(mode == .signIn ? "Sign in to your account" : "Create a new account")
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
    }
    
    // MARK: - Social Buttons
    
    private var socialButtons: some View {
        VStack(spacing: 10) {
            #if canImport(AuthenticationServices)
            // Sign in with Apple - Native button
            SignInWithAppleButton(
                mode == .signIn ? .signIn : .signUp,
                onRequest: { request in
                    request.requestedScopes = [.email, .fullName]
                },
                onCompletion: handleAppleSignIn
            )
            .signInWithAppleButtonStyle(.black)
            .frame(height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            #endif
            
            // Sign in with Google - Custom styled button matching Apple button
            Button(action: handleGoogleSignIn) {
                HStack(spacing: 10) {
                    // Google "G" logo
                    GoogleLogo()
                        .frame(width: 16, height: 16)
                    
                    Text(mode == .signIn ? "Sign in with Google" : "Sign up with Google")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(.primary.opacity(0.85))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 38)
                .background(Color(nsColor: .controlBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(Color.gray.opacity(0.4), lineWidth: 1)
                )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 24)
    }
    
    // MARK: - Email Form
    
    private var emailForm: some View {
        VStack(spacing: 12) {
            if mode == .signUp {
                TextField("Full Name", text: $fullName)
                    .textFieldStyle(.roundedBorder)
            }
            
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
            
            SecureField("Password", text: $password)
                .textFieldStyle(.roundedBorder)
                .textContentType(mode == .signIn ? .password : .newPassword)
            
            if mode == .signUp {
                SecureField("Confirm Password", text: $confirmPassword)
                    .textFieldStyle(.roundedBorder)
                    .textContentType(.newPassword)
            }
            
            if mode == .signIn {
                HStack {
                    Spacer()
                    Button("Forgot password?") {
                        showingForgotPassword = true
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
        .padding(.horizontal, 24)
    }
    
    // MARK: - Messages
    
    @ViewBuilder
    private var messages: some View {
        if let error = errorMessage {
            HStack {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundColor(.red)
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
                    .lineLimit(2)
            }
            .padding(.horizontal, 24)
        }
        
        if let success = successMessage {
            HStack {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundColor(.green)
                Text(success)
                    .font(.caption)
                    .foregroundColor(.green)
                    .lineLimit(2)
            }
            .padding(.horizontal, 24)
        }
    }
    
    // MARK: - Submit Button
    
    private var submitButton: some View {
        Button(action: handleEmailAuth) {
            if authService.isLoading {
                ProgressView()
                    .scaleEffect(0.8)
            } else {
                Text(mode == .signIn ? "Sign In" : "Create Account")
                    .fontWeight(.semibold)
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity)
        .frame(height: 44)
        .background(isFormValid ? Color.blue : Color.blue.opacity(0.5))
        .foregroundColor(.white)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .padding(.horizontal, 24)
        .disabled(authService.isLoading || !isFormValid)
    }
    
    // MARK: - Toggle Mode Button
    
    private var toggleModeButton: some View {
        HStack(spacing: 4) {
            Text(mode == .signIn ? "Don't have an account?" : "Already have an account?")
                .font(.caption)
                .foregroundColor(.secondary)
            
            Button(mode == .signIn ? "Sign Up" : "Sign In") {
                withAnimation(.easeInOut(duration: 0.2)) {
                    mode = mode == .signIn ? .signUp : .signIn
                    clearForm()
                }
            }
            .buttonStyle(.link)
            .font(.caption)
        }
    }
    
    // MARK: - Form Validation
    
    private var isFormValid: Bool {
        if mode == .signIn {
            return !email.isEmpty && !password.isEmpty
        } else {
            return !email.isEmpty && !password.isEmpty && password == confirmPassword && password.count >= 6
        }
    }
    
    private func clearForm() {
        email = ""
        password = ""
        confirmPassword = ""
        fullName = ""
        errorMessage = nil
        successMessage = nil
    }
    
    // MARK: - Actions
    
    private func handleEmailAuth() {
        errorMessage = nil
        successMessage = nil
        
        Task {
            do {
                if mode == .signIn {
                    try await authService.signIn(email: email, password: password)
                    dismiss()
                } else {
                    if password != confirmPassword {
                        errorMessage = "Passwords do not match"
                        return
                    }
                    try await authService.signUp(email: email, password: password, fullName: fullName.isEmpty ? nil : fullName)
                    successMessage = "Account created! Please check your email to verify."
                }
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
    
    #if canImport(AuthenticationServices)
    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) {
        switch result {
        case .success(let authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let identityTokenData = credential.identityToken,
                  let idToken = String(data: identityTokenData, encoding: .utf8) else {
                errorMessage = "Failed to get Apple credentials"
                return
            }
            
            let nonce = generateNonce()
            
            Task {
                do {
                    try await authService.signInWithApple(idToken: idToken, nonce: nonce)
                    dismiss()
                } catch {
                    errorMessage = error.localizedDescription
                }
            }
            
        case .failure(let error):
            if (error as NSError).code != ASAuthorizationError.canceled.rawValue {
                errorMessage = error.localizedDescription
            }
        }
    }
    #endif
    
    private func handleGoogleSignIn() {
        errorMessage = "Google Sign-In coming soon. Please use Apple or email for now."
    }
    
    private func generateNonce(length: Int = 32) -> String {
        let charset: [Character] = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVXYZabcdefghijklmnopqrstuvwxyz-._")
        var result = ""
        var remainingLength = length
        
        while remainingLength > 0 {
            let randoms: [UInt8] = (0..<16).map { _ in
                var random: UInt8 = 0
                _ = SecRandomCopyBytes(kSecRandomDefault, 1, &random)
                return random
            }
            
            randoms.forEach { random in
                if remainingLength == 0 { return }
                if random < charset.count {
                    result.append(charset[Int(random)])
                    remainingLength -= 1
                }
            }
        }
        return result
    }
}

// MARK: - Auth Mode

private enum AuthMode {
    case signIn
    case signUp
}

// MARK: - Musio Logo (loads SVG from app bundle)

struct MusioLogo: View {
    var body: some View {
        #if canImport(AppKit)
        if let resourcePath = Bundle.main.path(forResource: "MusioLogo", ofType: "svg"),
           let image = NSImage(contentsOfFile: resourcePath) {
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fit)
        } else {
            // Fallback if SVG not found
            Image(systemName: "music.note")
                .resizable()
                .aspectRatio(contentMode: .fit)
                .foregroundColor(.blue)
        }
        #else
        // TODO(windows): Add cross-platform SVG asset loading for brand marks.
        Image(systemName: "music.note")
            .resizable()
            .aspectRatio(contentMode: .fit)
            .foregroundColor(.blue)
        #endif
    }
}

// MARK: - Google Logo

struct GoogleLogo: View {
    var body: some View {
        // Google "G" logo with official colors
        ZStack {
            // Blue
            Circle()
                .trim(from: 0.0, to: 0.25)
                .stroke(Color(red: 66/255, green: 133/255, blue: 244/255), lineWidth: 3)
            // Green
            Circle()
                .trim(from: 0.25, to: 0.5)
                .stroke(Color(red: 52/255, green: 168/255, blue: 83/255), lineWidth: 3)
            // Yellow
            Circle()
                .trim(from: 0.5, to: 0.75)
                .stroke(Color(red: 251/255, green: 188/255, blue: 5/255), lineWidth: 3)
            // Red
            Circle()
                .trim(from: 0.75, to: 1.0)
                .stroke(Color(red: 234/255, green: 67/255, blue: 53/255), lineWidth: 3)
        }
        .rotationEffect(.degrees(-90))
    }
}

// MARK: - Forgot Password View

struct ForgotPasswordView: View {
    @ObservedObject private var authService = SupabaseAuthService.shared
    @State private var email = ""
    @State private var message: String?
    @State private var isError = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Reset Password")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Enter your email address and we'll send you a link to reset your password.")
                .font(.caption)
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
            
            TextField("Email", text: $email)
                .textFieldStyle(.roundedBorder)
                .textContentType(.emailAddress)
            
            if let message = message {
                Text(message)
                    .font(.caption)
                    .foregroundColor(isError ? .red : .green)
            }
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button("Send Reset Link") {
                    Task {
                        do {
                            try await authService.resetPassword(email: email)
                            message = "Password reset email sent!"
                            isError = false
                        } catch {
                            message = error.localizedDescription
                            isError = true
                        }
                    }
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(email.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 350)
    }
}
