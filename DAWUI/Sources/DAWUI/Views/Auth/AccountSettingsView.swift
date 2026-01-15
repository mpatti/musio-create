import SwiftUI
import DAWCore

// MARK: - Account Settings View

public struct AccountSettingsView: View {
    @ObservedObject private var authService = SupabaseAuthService.shared
    @State private var showingSignOutConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var showingSupabaseConfig = false
    @Environment(\.dismiss) private var dismiss
    
    public init() {}
    
    public var body: some View {
        VStack(spacing: 0) {
            // Header with close button
            HStack {
                Text("Account")
                    .font(.title2)
                    .fontWeight(.bold)
                
                Spacer()
                
                Button(action: { dismiss() }) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.title2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            
            Divider()
            
            if authService.isAuthenticated, let user = authService.currentUser {
                loggedInView(user: user)
            } else {
                notLoggedInView
            }
        }
        .frame(width: 360, height: 400)
        .background(Color(nsColor: .windowBackgroundColor))
        .alert("Sign Out", isPresented: $showingSignOutConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Sign Out", role: .destructive) {
                Task {
                    try? await authService.signOut()
                    dismiss()
                }
            }
        } message: {
            Text("Are you sure you want to sign out?")
        }
        .alert("Delete Account", isPresented: $showingDeleteConfirmation) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                Task {
                    try? await authService.deleteAccount()
                    dismiss()
                }
            }
        } message: {
            Text("This action cannot be undone. All your data will be permanently deleted.")
        }
        .sheet(isPresented: $showingSupabaseConfig) {
            SupabaseConfigView()
        }
    }
    
    // MARK: - Logged In View
    
    private func loggedInView(user: AuthUser) -> some View {
        VStack(spacing: 0) {
            // User info section
            VStack(spacing: 10) {
                // Avatar
                if let avatarURL = user.avatarURL, let url = URL(string: avatarURL) {
                    AsyncImage(url: url) { image in
                        image
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                    } placeholder: {
                        Image(systemName: "person.circle.fill")
                            .resizable()
                    }
                    .frame(width: 70, height: 70)
                    .clipShape(Circle())
                } else {
                    Image(systemName: "person.circle.fill")
                        .resizable()
                        .frame(width: 70, height: 70)
                        .foregroundColor(.blue)
                }
                
                // Name
                if let name = user.fullName {
                    Text(name)
                        .font(.headline)
                }
                
                // Email
                if let email = user.email {
                    Text(email)
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
                
                // Provider badge
                HStack(spacing: 6) {
                    Image(systemName: providerIcon(user.provider))
                        .font(.caption)
                    Text("Signed in with \(providerName(user.provider))")
                        .font(.caption)
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Color.gray.opacity(0.15))
                .clipShape(Capsule())
            }
            .padding(.vertical, 20)
            
            Divider()
                .padding(.horizontal, 20)
            
            // Account info & actions
            VStack(spacing: 16) {
                // Member since
                HStack {
                    Text("Member since")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Spacer()
                    Text(user.createdAt, style: .date)
                        .font(.subheadline)
                }
                .padding(.horizontal, 20)
                .padding(.top, 16)
                
                Spacer()
                
                // Buttons
                VStack(spacing: 10) {
                    Button(action: { showingSignOutConfirmation = true }) {
                        HStack {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                            Text("Sign Out")
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                    }
                    .buttonStyle(.bordered)
                    
                    Button(action: { showingDeleteConfirmation = true }) {
                        HStack {
                            Image(systemName: "trash")
                            Text("Delete Account")
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 40)
                    }
                    .buttonStyle(.bordered)
                    .tint(.red)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 20)
            }
        }
    }
    
    // MARK: - Not Logged In View
    
    private var notLoggedInView: some View {
        VStack(spacing: 20) {
            Spacer()
            
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 56))
                .foregroundColor(.secondary)
            
            if !authService.isConfigured {
                Text("Supabase Not Configured")
                    .font(.headline)
                
                Text("Configure your Supabase project\nto enable authentication.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
                
                Button("Configure Supabase") {
                    showingSupabaseConfig = true
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("Not Signed In")
                    .font(.headline)
                
                Text("Sign in to sync your projects\nand preferences across devices.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                    .multilineTextAlignment(.center)
            }
            
            Spacer()
        }
        .padding()
    }
    
    // MARK: - Helpers
    
    private func providerIcon(_ provider: AuthProvider) -> String {
        switch provider {
        case .email: return "envelope.fill"
        case .apple: return "apple.logo"
        case .google: return "g.circle.fill"
        }
    }
    
    private func providerName(_ provider: AuthProvider) -> String {
        switch provider {
        case .email: return "Email"
        case .apple: return "Apple"
        case .google: return "Google"
        }
    }
}

// MARK: - Supabase Config View

struct SupabaseConfigView: View {
    @ObservedObject private var authService = SupabaseAuthService.shared
    @State private var supabaseURL = ""
    @State private var supabaseAnonKey = ""
    @State private var showingHelp = false
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Configure Supabase")
                .font(.title2)
                .fontWeight(.bold)
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Supabase Project URL")
                    .font(.caption)
                    .foregroundColor(.secondary)
                TextField("https://your-project.supabase.co", text: $supabaseURL)
                    .textFieldStyle(.roundedBorder)
            }
            
            VStack(alignment: .leading, spacing: 8) {
                Text("Anon Public Key")
                    .font(.caption)
                    .foregroundColor(.secondary)
                SecureField("eyJhbGciOiJI...", text: $supabaseAnonKey)
                    .textFieldStyle(.roundedBorder)
            }
            
            Button(action: { showingHelp = true }) {
                HStack {
                    Image(systemName: "questionmark.circle")
                    Text("Where do I find these?")
                }
                .font(.caption)
            }
            .buttonStyle(.link)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                
                Spacer()
                
                Button("Save") {
                    authService.configure(url: supabaseURL, anonKey: supabaseAnonKey)
                    dismiss()
                }
                .keyboardShortcut(.return)
                .buttonStyle(.borderedProminent)
                .disabled(supabaseURL.isEmpty || supabaseAnonKey.isEmpty)
            }
        }
        .padding(24)
        .frame(width: 420)
        .alert("Finding Your Supabase Credentials", isPresented: $showingHelp) {
            Button("OK") {}
        } message: {
            Text("""
            1. Go to supabase.com and sign in
            2. Select or create a project
            3. Go to Project Settings → API
            4. Copy the "Project URL" and "anon public" key
            """)
        }
    }
}
