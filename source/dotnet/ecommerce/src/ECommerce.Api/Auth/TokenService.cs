using System.Text;
using ECommerce.Api.Configuration;
using ECommerce.Api.Data;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace ECommerce.Api.Auth;

public sealed class TokenService(EcommerceSettings settings)
{
    private readonly SigningCredentials _credentials = new(
        new SymmetricSecurityKey(Encoding.UTF8.GetBytes(settings.JwtKey)),
        SecurityAlgorithms.HmacSha256);

    public string Issue(User user)
    {
        var descriptor = new SecurityTokenDescriptor
        {
            Issuer = settings.JwtIssuer,
            Audience = settings.JwtAudience,
            Expires = DateTime.UtcNow.AddMinutes(settings.JwtLifetimeMinutes),
            SigningCredentials = _credentials,
            Claims = new Dictionary<string, object>
            {
                [JwtRegisteredClaimNames.Sub] = user.Id.ToString(),
                [JwtRegisteredClaimNames.Name] = user.Username,
                ["role"] = user.Role
            }
        };

        return new JsonWebTokenHandler().CreateToken(descriptor);
    }
}
