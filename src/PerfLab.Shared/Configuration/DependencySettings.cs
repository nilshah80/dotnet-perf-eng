namespace PerfLab.Shared.Configuration;

public sealed record DependencySettings(
    string PostgreSql,
    string Redis,
    string RabbitMqHost,
    int RabbitMqPort,
    string RabbitMqUser,
    string RabbitMqPassword)
{
    public static DependencySettings FromEnvironment() => new(
        Environment.GetEnvironmentVariable("ConnectionStrings__PostgreSql")
            ?? "Host=localhost;Port=5432;Database=perflab;Username=perflab;Password=perflab;Maximum Pool Size=20;Timeout=5;Command Timeout=5;GSS Encryption Mode=Disable",
        Environment.GetEnvironmentVariable("ConnectionStrings__Redis")
            ?? "localhost:6379,abortConnect=false,connectTimeout=5000,syncTimeout=3000",
        Environment.GetEnvironmentVariable("RabbitMq__Host") ?? "localhost",
        int.TryParse(Environment.GetEnvironmentVariable("RabbitMq__Port"), out var port) ? port : 5672,
        Environment.GetEnvironmentVariable("RabbitMq__User") ?? "perflab",
        Environment.GetEnvironmentVariable("RabbitMq__Password") ?? "perflab");
}
