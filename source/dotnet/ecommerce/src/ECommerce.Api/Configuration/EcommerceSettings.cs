namespace ECommerce.Api.Configuration;

public sealed record EcommerceSettings(
    string PostgreSql,
    string JwtKey,
    string JwtIssuer,
    string JwtAudience,
    int JwtLifetimeMinutes)
{
    public static EcommerceSettings FromEnvironment() => new(
        Environment.GetEnvironmentVariable("ConnectionStrings__PostgreSql")
            ?? "Host=localhost;Port=5432;Database=ecommerce;Username=ecommerce;Password=ecommerce;Maximum Pool Size=20;Minimum Pool Size=0;Timeout=5;Command Timeout=5;GSS Encryption Mode=Disable;Application Name=ecommerce-api",
        // Local-development signing key only. Overridden per run via Jwt__Key in
        // compose; never a production secret. HS256 needs >= 256 bits (32 chars).
        Environment.GetEnvironmentVariable("Jwt__Key")
            ?? "ecommerce-lab-local-dev-signing-key-do-not-use-in-production",
        Environment.GetEnvironmentVariable("Jwt__Issuer") ?? "ecommerce-lab",
        Environment.GetEnvironmentVariable("Jwt__Audience") ?? "ecommerce-lab",
        int.TryParse(Environment.GetEnvironmentVariable("Jwt__LifetimeMinutes"), out var minutes) ? minutes : 30);
}
