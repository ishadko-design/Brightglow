import Foundation
import Supabase

/// The shared Supabase client.
///
/// Credentials come from the gitignored `Secrets.xcconfig` via `Info.plist`, the
/// same path BusinessPhotoService / LogoService / VerdictService already use —
/// `SUPABASE_REF` is the project ref rather than the full URL because "//" starts
/// a comment in xcconfig. No hardcoded fallback: an unconfigured build should
/// fail loudly against an invalid host, not silently talk to a baked-in project.
private let supabaseRef: String =
    (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_REF") as? String) ?? ""
private let supabaseAnonKey: String =
    (Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String) ?? ""

let supabase = SupabaseClient(
    supabaseURL: URL(string: "https://\(supabaseRef).supabase.co")!,
    supabaseKey: supabaseAnonKey,
    options: SupabaseClientOptions(
        // Opt in ahead of supabase-swift's next major, which makes this the
        // default. A no-op for us: AuthService ignores `.initialSession` and
        // restores through `supabase.auth.session`, which refreshes or throws —
        // so an expired local session can never reach `user`. Silences the
        // startup warning and makes that upgrade a non-event.
        auth: SupabaseClientOptions.AuthOptions(
            emitLocalSessionAsInitialSession: true
        )
    )
)
