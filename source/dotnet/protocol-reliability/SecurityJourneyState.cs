using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;

namespace ProtocolReliability;

// This is deliberately a small, self-contained fixture rather than an
// authentication product. Its job is to make the load journey exercise the
// security transitions that a real browser/client must make: a cookie-bound
// session, an expired access token, a refresh-token rotation, and a CSRF
// protected mutation. Tokens are opaque and are never logged or exported in
// telemetry.
public sealed class SecurityJourneyState
{
    private readonly ConcurrentDictionary<string, Session> _sessions = new();
    private long _logins;
    private long _refreshes;
    private long _submissions;
    private long _rejected;

    public LoginResult CreateLogin()
    {
        var session = new Session(
            RandomToken(),
            RandomToken(),
            RandomToken(),
            RandomToken());
        if (!_sessions.TryAdd(session.ID, session))
        {
            // An ID collision is astronomically unlikely, but a fixture must
            // fail closed rather than issue two identities for one session.
            throw new InvalidOperationException("Unable to allocate a unique security journey session.");
        }

        Interlocked.Increment(ref _logins);
        return new LoginResult(session.ID, session.ExpiredAccessToken, session.RefreshToken);
    }

    public bool TryGetForm(string? sessionID, out string csrfToken)
    {
        csrfToken = string.Empty;
        if (!TryGet(sessionID, out var session))
        {
            Interlocked.Increment(ref _rejected);
            return false;
        }

        lock (session.Gate)
        {
            csrfToken = session.CsrfToken;
            return true;
        }
    }

    public AccessResult CheckAccess(string? sessionID, string? bearerToken)
    {
        if (!TryGet(sessionID, out var session))
        {
            Interlocked.Increment(ref _rejected);
            return AccessResult.SessionRequired;
        }

        lock (session.Gate)
        {
            if (TokenEquals(session.ActiveAccessToken, bearerToken))
            {
                return AccessResult.Active;
            }

            Interlocked.Increment(ref _rejected);
            return TokenEquals(session.ExpiredAccessToken, bearerToken)
                ? AccessResult.Expired
                : AccessResult.Invalid;
        }
    }

    public bool TryRefresh(string? sessionID, string? refreshToken, out RefreshResult result)
    {
        result = new RefreshResult(string.Empty, string.Empty, string.Empty);
        if (!TryGet(sessionID, out var session))
        {
            Interlocked.Increment(ref _rejected);
            return false;
        }

        lock (session.Gate)
        {
            if (!TokenEquals(session.RefreshToken, refreshToken))
            {
                Interlocked.Increment(ref _rejected);
                return false;
            }

            // Rotation makes replay of the prior refresh credential fail.
            session.ActiveAccessToken = RandomToken();
            session.RefreshToken = RandomToken();
            session.CsrfToken = RandomToken();
            result = new RefreshResult(session.ActiveAccessToken, session.RefreshToken,
                session.CsrfToken);
            Interlocked.Increment(ref _refreshes);
            return true;
        }
    }

    public SubmitResult TrySubmit(string? sessionID, string? bearerToken, string? csrfToken)
    {
        if (!TryGet(sessionID, out var session))
        {
            Interlocked.Increment(ref _rejected);
            return SubmitResult.SessionRequired;
        }

        lock (session.Gate)
        {
            if (!TokenEquals(session.ActiveAccessToken, bearerToken))
            {
                Interlocked.Increment(ref _rejected);
                return SubmitResult.AccessDenied;
            }
            if (!TokenEquals(session.CsrfToken, csrfToken))
            {
                Interlocked.Increment(ref _rejected);
                return SubmitResult.CsrfDenied;
            }

            session.CsrfToken = RandomToken();
            session.Submissions++;
            Interlocked.Increment(ref _submissions);
            return new SubmitResult(SubmitDisposition.Accepted, session.Submissions, session.CsrfToken);
        }
    }

    public object Snapshot() => new
    {
        activeSessions = _sessions.Count,
        logins = Interlocked.Read(ref _logins),
        refreshes = Interlocked.Read(ref _refreshes),
        submissions = Interlocked.Read(ref _submissions),
        rejected = Interlocked.Read(ref _rejected)
    };

    private bool TryGet(string? sessionID, out Session session)
    {
        if (!string.IsNullOrWhiteSpace(sessionID) && _sessions.TryGetValue(sessionID, out var found))
        {
            session = found;
            return true;
        }
        session = null!;
        return false;
    }

    private static string RandomToken() => Convert.ToHexString(RandomNumberGenerator.GetBytes(32));

    private static bool TokenEquals(string? left, string? right)
    {
        if (string.IsNullOrEmpty(left) || string.IsNullOrEmpty(right))
        {
            return false;
        }
        var leftBytes = Encoding.UTF8.GetBytes(left);
        var rightBytes = Encoding.UTF8.GetBytes(right);
        try
        {
            return CryptographicOperations.FixedTimeEquals(leftBytes, rightBytes);
        }
        finally
        {
            CryptographicOperations.ZeroMemory(leftBytes);
            CryptographicOperations.ZeroMemory(rightBytes);
        }
    }

    private sealed class Session(string id, string expiredAccessToken, string refreshToken,
        string csrfToken)
    {
        public object Gate { get; } = new();
        public string ID { get; } = id;
        public string ExpiredAccessToken { get; } = expiredAccessToken;
        public string? ActiveAccessToken { get; set; }
        public string RefreshToken { get; set; } = refreshToken;
        public string CsrfToken { get; set; } = csrfToken;
        public long Submissions { get; set; }
    }
}

public sealed record LoginResult(string SessionID, string AccessToken, string RefreshToken);
public sealed record RefreshResult(string AccessToken, string RefreshToken, string CsrfToken);

public sealed record SubmitResult(SubmitDisposition Disposition, long Submission, string? NextCsrfToken)
{
    public bool Accepted => Disposition == SubmitDisposition.Accepted;
    public static SubmitResult SessionRequired { get; } = new(SubmitDisposition.SessionRequired, 0, null);
    public static SubmitResult AccessDenied { get; } = new(SubmitDisposition.AccessDenied, 0, null);
    public static SubmitResult CsrfDenied { get; } = new(SubmitDisposition.CsrfDenied, 0, null);
}

public enum SubmitDisposition
{
    Accepted,
    SessionRequired,
    AccessDenied,
    CsrfDenied
}

public enum AccessResult
{
    Active,
    Expired,
    Invalid,
    SessionRequired
}
