import SwiftUI

struct AuthView: View {
    @EnvironmentObject private var auth: AuthViewModel

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var username: String = ""
    @State private var isSignUp: Bool = true
    @State private var otpCode: String = ""

    private var brandPurple: Color {
        Color(red: 0.48, green: 0.23, blue: 0.93)
    }

    private var canSubmit: Bool {
        if auth.isLoading { return false }
        if email.isEmpty || password.isEmpty { return false }
        if isSignUp && username.isEmpty { return false }
        return true
    }

    var body: some View {
        ZStack {
            // Clean white background with subtle green accent at top
            Color.white.ignoresSafeArea()

            // Subtle green gradient at the very top
            VStack {
                LinearGradient(
                    colors: [
                        brandPurple.opacity(0.12),
                        Color.white
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
                .frame(height: 280)
                Spacer()
            }
            .ignoresSafeArea()

            if auth.awaitingEmailConfirmation {
                otpVerificationContent
            } else {
                signInSignUpContent
            }
        }
    }

    // MARK: - Sign In / Sign Up

    private var signInSignUpContent: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer().frame(height: 50)

                // Logo / Title
                VStack(spacing: 10) {
                    // Use the actual app icon asset so the logo on the auth screen always
                    // matches the home-screen icon — no font/clipping issues to chase.
                    Image("AppLogo")
                        .resizable()
                        .scaledToFill()
                        .frame(width: 78, height: 78)
                        .clipShape(RoundedRectangle(cornerRadius: 18))

                    Text("DuelFantasy")
                        .font(.custom("Lobster-Regular", size: 34))
                        .foregroundStyle(Color(red: 0.12, green: 0.14, blue: 0.18))

                    Text("Sports Pick'em & Fantasy, Reimagined.")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)

                    Text(isSignUp ? "Create your account" : "Welcome back")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }

                // Form card
                VStack(spacing: 14) {
                    if isSignUp {
                        AuthTextField(
                            icon: "person",
                            placeholder: "Username",
                            text: $username
                        )
                    }

                    AuthTextField(
                        icon: "envelope",
                        placeholder: "Email",
                        text: $email,
                        isEmail: true
                    )

                    AuthTextField(
                        icon: "lock",
                        placeholder: "Password",
                        text: $password,
                        isSecure: true
                    )

                    if let error = auth.errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                            Text(error)
                                .font(.caption)
                        }
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Haptics.medium()
                        Task {
                            if isSignUp {
                                await auth.signUp(
                                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                    password: password,
                                    username: username.trimmingCharacters(in: .whitespacesAndNewlines)
                                )
                            } else {
                                await auth.signIn(
                                    email: email.trimmingCharacters(in: .whitespacesAndNewlines),
                                    password: password,
                                    usernameFallback: ""
                                )
                            }
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if auth.isLoading {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text(isSignUp ? "Create Account" : "Sign In")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(canSubmit ? brandPurple : Color(.systemGray4))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(!canSubmit)
                }
                .padding(24)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 4)
                .padding(.horizontal, 24)

                // Toggle sign in / sign up
                Button {
                    Haptics.light()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        isSignUp.toggle()
                        auth.errorMessage = nil
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(isSignUp ? "Already have an account?" : "Don't have an account?")
                            .foregroundStyle(.secondary)
                        Text(isSignUp ? "Sign In" : "Sign Up")
                            .foregroundStyle(brandPurple)
                            .fontWeight(.semibold)
                    }
                    .font(.subheadline)
                }

                Spacer()
            }
        }
    }

    // MARK: - OTP Verification

    private var otpVerificationContent: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer().frame(height: 60)

                VStack(spacing: 12) {
                    Image(systemName: "envelope.badge")
                        .font(.system(size: 48))
                        .foregroundStyle(brandPurple)

                    Text("Check Your Email")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(Color(red: 0.12, green: 0.14, blue: 0.18))

                    Text("We sent a 6-digit code to")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    Text(auth.pendingEmail)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color(red: 0.12, green: 0.14, blue: 0.18))
                }

                // OTP card
                VStack(spacing: 16) {
                    AuthTextField(
                        icon: "number",
                        placeholder: "6-digit code",
                        text: $otpCode
                    )

                    if let error = auth.errorMessage {
                        HStack(spacing: 8) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .font(.caption)
                            Text(error)
                                .font(.caption)
                        }
                        .foregroundStyle(.red)
                        .padding(.horizontal, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Button {
                        Haptics.medium()
                        Task {
                            await auth.verifyOTP(code: otpCode.trimmingCharacters(in: .whitespacesAndNewlines))
                        }
                    } label: {
                        HStack(spacing: 8) {
                            if auth.isLoading {
                                ProgressView()
                                    .tint(.white)
                            }
                            Text("Verify")
                                .font(.headline)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                        .background(!otpCode.isEmpty && !auth.isLoading ? brandPurple : Color(.systemGray4))
                        .foregroundStyle(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 14))
                    }
                    .disabled(otpCode.isEmpty || auth.isLoading)
                }
                .padding(24)
                .background(Color(.systemBackground))
                .clipShape(RoundedRectangle(cornerRadius: 20))
                .shadow(color: .black.opacity(0.08), radius: 16, x: 0, y: 4)
                .padding(.horizontal, 24)

                Button {
                    Haptics.light()
                    Task {
                        await auth.resendConfirmationEmail()
                    }
                } label: {
                    Text("Resend Code")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(brandPurple)
                }
                .disabled(auth.isLoading)

                Button {
                    Haptics.light()
                    auth.cancelEmailConfirmation()
                    otpCode = ""
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "arrow.left")
                        Text("Back to Sign Up")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                Button {
                    Haptics.light()
                    auth.cancelEmailConfirmation()
                    otpCode = ""
                    isSignUp = false
                } label: {
                    Text("Already confirmed? Sign In")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

                Spacer()
            }
        }
    }
}

// MARK: - Custom Text Field

private struct AuthTextField: View {
    let icon: String
    let placeholder: String
    @Binding var text: String
    var isEmail: Bool = false
    var isSecure: Bool = false

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.secondary)
                .frame(width: 20)

            if isSecure {
                SecureField(placeholder, text: $text)
                    .foregroundStyle(.primary)
                    .tint(Color(red: 0.48, green: 0.23, blue: 0.93))
            } else {
                TextField(placeholder, text: $text)
                    .foregroundStyle(.primary)
                    .tint(Color(red: 0.48, green: 0.23, blue: 0.93))
                    .textInputAutocapitalization(isEmail ? .never : .words)
                    .autocorrectionDisabled(isEmail)
                    .keyboardType(isEmail ? .emailAddress : .default)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .background(Color(.systemGray6))
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}

#Preview {
    AuthView()
        .environmentObject(AuthViewModel())
}
