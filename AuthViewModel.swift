import Foundation
import SwiftUI
import Combine

@MainActor
final class AuthViewModel: ObservableObject {
    @Published var session: SupabaseAuthSession?
    @Published var isLoading: Bool = false
    @Published var errorMessage: String?
    @Published var awaitingEmailConfirmation: Bool = false

    /// Email/username stashed during sign-up so OTP verification can finish the flow.
    private(set) var pendingEmail: String = ""
    private(set) var pendingPassword: String = ""
    private(set) var pendingUsername: String = ""

    private let sessionKey = "supabase_auth_session"
    /// Prevents concurrent refresh attempts (e.g. multiple 401s at once)
    private var activeRefreshTask: Task<String?, Never>?

    var isAuthenticated: Bool {
        session != nil
    }

    var userID: String? {
        session?.user.id
    }

    var userEmail: String {
        session?.user.email ?? ""
    }

    var accessToken: String? {
        session?.accessToken
    }

    init() {
        loadPersistedSession()
        installTokenRefreshProvider()
        Task { await refreshSessionIfNeeded() }
    }

    /// Installs a closure on SupabaseService that auto-refreshes the token on 401 responses.
    private func installTokenRefreshProvider() {
        SupabaseService.shared.tokenRefreshProvider = { [weak self] in
            guard let self else { return nil }
            return await self.performTokenRefresh()
        }
    }

    /// Refreshes the session and returns the new access token, or nil on failure.
    /// Called both proactively (scenePhase) and reactively (401 retry from SupabaseService).
    /// Serialized: if multiple 401s arrive simultaneously, only one refresh runs.
    func performTokenRefresh() async -> String? {
        // If a refresh is already in flight, await it instead of starting another
        if let existing = activeRefreshTask {
            return await existing.value
        }

        let task = Task<String?, Never> {
            guard let currentSession = session,
                  let refreshToken = currentSession.refreshToken,
                  !refreshToken.isEmpty else { return nil }

            do {
                let refreshed = try await SupabaseService.shared.refreshSession(refreshToken: refreshToken)
                session = refreshed
                persistSession(refreshed)
                return refreshed.accessToken
            } catch {
                let message = error.localizedDescription.lowercased()
                // `already_used` historically signalled a race between two
                // concurrent refreshes, but `activeRefreshTask` serialises
                // refreshes so a genuine race can't happen anymore. Hitting
                // this branch means the persisted refresh token is dead —
                // typically because a prior `persistSession` write was
                // silently dropped (e.g., CFPreferences in direct mode from
                // a 4 MB+ blob overflow). Sign the user out so they can
                // re-auth and get a fresh refresh token, instead of looping
                // forever on the dead one.
                let isAlreadyUsed = message.contains("already used")
                    || message.contains("already_used")
                let isAuthRejection = isAlreadyUsed
                    || message.contains("not found") || message.contains("not_found")
                    || message.contains("revoked")
                    || message.contains("token expired") || message.contains("token_expired")
                    || message.contains("unauthorized")
                if isAuthRejection {
                    print("[Auth] Token refresh rejected — signing out: \(error.localizedDescription)")
                    session = nil
                    UserDefaults.standard.removeObject(forKey: sessionKey)
                } else {
                    print("[Auth] Token refresh failed (transient) — keeping session: \(error.localizedDescription)")
                }
                return nil
            }
        }
        activeRefreshTask = task
        let result = await task.value
        activeRefreshTask = nil
        return result
    }

    func signUp(email: String, password: String, username: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let authSession = try await SupabaseService.shared.signUp(email: email, password: password)
            session = authSession
            persistSession(authSession)
            try await ensureProfile(username: username)
        } catch let error as SupabaseServiceError {
            switch error {
            case .emailConfirmationRequired:
                // User was created and confirmation email was sent — go to OTP screen
                pendingEmail = email
                pendingPassword = password
                pendingUsername = username
                awaitingEmailConfirmation = true
            case .userAlreadyExists:
                errorMessage = "An account with this email already exists. Please sign in instead."
            case .rateLimited:
                // 429 — email rate limited. Account may or may not have been created.
                errorMessage = "Email rate limited. Wait a minute, then try signing in. If that fails, try signing up again."
            default:
                errorMessage = error.errorDescription ?? error.localizedDescription
            }
        } catch {
            errorMessage = userFriendlyAuthMessage(for: error, isSignUp: true)
        }
        isLoading = false
    }

    func verifyOTP(code: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let authSession = try await SupabaseService.shared.verifyOTP(email: pendingEmail, token: code)
            session = authSession
            persistSession(authSession)
            try await ensureProfile(username: pendingUsername)
            awaitingEmailConfirmation = false
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    func resendConfirmationEmail() async {
        isLoading = true
        errorMessage = nil
        do {
            try await SupabaseService.shared.resendConfirmationEmail(email: pendingEmail)
            errorMessage = nil
        } catch {
            // Even if resend fails (rate limit), don't leave the OTP screen
            let msg = error.localizedDescription.lowercased()
            if msg.contains("rate limit") {
                errorMessage = "Please wait a minute before requesting another code."
            } else {
                errorMessage = error.localizedDescription
            }
        }
        isLoading = false
    }

    func cancelEmailConfirmation() {
        awaitingEmailConfirmation = false
        pendingEmail = ""
        pendingPassword = ""
        pendingUsername = ""
        errorMessage = nil
    }

    func signIn(email: String, password: String, usernameFallback: String) async {
        isLoading = true
        errorMessage = nil
        do {
            let authSession = try await SupabaseService.shared.signIn(email: email, password: password)
            session = authSession
            persistSession(authSession)
            try await ensureProfile(username: usernameFallback)
        } catch {
            errorMessage = userFriendlyAuthMessage(for: error, isSignUp: false)
        }
        isLoading = false
    }

    func refreshSessionIfNeeded() async {
        guard let currentSession = session,
              let refreshToken = currentSession.refreshToken,
              !refreshToken.isEmpty else { return }

        // Check if the JWT is expired or about to expire (within 5 minutes)
        if let expiration = jwtExpiration(from: currentSession.accessToken),
           expiration > Date().addingTimeInterval(300) {
            return // Token is still valid for more than 5 minutes
        }

        // Route through performTokenRefresh so we share the activeRefreshTask
        // serialization. Without this, multiple concurrent callers (init +
        // scenePhase + .task on launch + 9 polling tasks) could each fire
        // their own refreshSession with the same refresh token. Supabase
        // rotates the refresh token on success, so the losers get back
        // "Invalid Refresh Token: Already Used" which previously matched the
        // "invalid" substring heuristic and signed the user out by mistake.
        _ = await performTokenRefresh()
    }

    private func jwtExpiration(from token: String) -> Date? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var base64 = String(parts[1])
        // Pad to multiple of 4
        while base64.count % 4 != 0 {
            base64.append("=")
        }
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let exp = json["exp"] as? TimeInterval else {
            return nil
        }
        return Date(timeIntervalSince1970: exp)
    }

    func signOut() async {
        if let token = accessToken {
            await SupabaseService.shared.signOut(accessToken: token)
        }
        session = nil
        UserDefaults.standard.removeObject(forKey: sessionKey)
    }

    /// Permanently deletes the user's account and all associated server data,
    /// then clears the local session. Required for Apple App Review 5.1.1(v).
    /// Returns true on success, false (with `error` set) on failure.
    @discardableResult
    func deleteAccount() async -> Bool {
        guard let token = accessToken else {
            errorMessage = "Not signed in"
            return false
        }
        do {
            try await SupabaseService.shared.deleteCurrentUser(accessToken: token)
            session = nil
            UserDefaults.standard.removeObject(forKey: sessionKey)
            return true
        } catch {
            errorMessage = "Couldn't delete account: \(error.localizedDescription)"
            return false
        }
    }

    private func ensureProfile(username: String) async throws {
        guard let userID, let accessToken else { return }

        // Check if profile already exists — don't overwrite existing username with email fallback
        let existing = try await SupabaseService.shared.fetchProfiles(userIDs: [userID], accessToken: accessToken)
        if let profile = existing.first, !profile.username.isEmpty, profile.username != "Player" {
            // Profile exists with a real username — only update if caller provided an explicit username
            if !username.isEmpty {
                try await SupabaseService.shared.upsertProfile(userID: userID, username: username, accessToken: accessToken)
            }
            return
        }

        // No profile or default name — create with provided username or email fallback
        let finalName = username.isEmpty ? (userEmail.components(separatedBy: "@").first ?? "Player") : username
        try await SupabaseService.shared.upsertProfile(userID: userID, username: finalName, accessToken: accessToken)
    }

    private func persistSession(_ session: SupabaseAuthSession) {
        guard let encoded = try? JSONEncoder().encode(session) else {
            print("[Auth] persistSession: encoding failed")
            return
        }
        let defaults = UserDefaults.standard
        defaults.set(encoded, forKey: sessionKey)
        // CFPreferences can silently drop writes when the defaults domain
        // is over its size budget (the 4 MB blob overflow that originally
        // caused this whole class of bug). Verify the round-trip so the
        // failure surfaces immediately instead of stranding the user on a
        // dead refresh token after the next launch.
        if defaults.data(forKey: sessionKey) != encoded {
            print("[Auth] persistSession: UserDefaults write was dropped — session NOT persisted")
        }
    }

    private func loadPersistedSession() {
        guard let data = UserDefaults.standard.data(forKey: sessionKey),
              let decoded = try? JSONDecoder().decode(SupabaseAuthSession.self, from: data) else {
            return
        }
        session = decoded
    }

    private func userFriendlyAuthMessage(for error: Error, isSignUp: Bool) -> String {
        let message = error.localizedDescription
        let normalized = message.lowercased()
        if normalized.contains("rate limit") || normalized.contains("over_email_send") {
            return "Too many requests. Please wait a minute and try again."
        }
        if normalized.contains("invalid login credentials") {
            return isSignUp ? "An account with this email may already exist. Try signing in." : "Invalid email or password."
        }
        return message
    }
}
