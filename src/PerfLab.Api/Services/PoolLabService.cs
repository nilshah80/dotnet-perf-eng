using System.Diagnostics;
using System.Globalization;
using Npgsql;
using PerfLab.Api.Contracts;
using PerfLab.Shared.Configuration;
using PerfLab.Shared.Diagnostics;
using StackExchange.Redis;

namespace PerfLab.Api.Services;

public sealed class PoolLabService : IAsyncDisposable
{
    private const int PostgresLowPoolSize = 2;
    private const int PostgresHighPoolSize = 64;
    private const int RedisLowPoolSize = 1;
    private const int RedisHighPoolSize = 32;
    private const int HttpLowPoolSize = 2;
    private const int HttpHighPoolSize = 128;

    private readonly DependencySettings _dependencySettings;
    private readonly LabRunContext _runContext;
    private readonly ILogger<PoolLabService> _logger;
    private readonly NpgsqlDataSource? _postgresDataSource;
    private readonly Lazy<Task<RedisPoolSlot[]>>? _redisPool;
    private readonly HttpClient? _httpClient;
    private readonly int _configuredSize;
    private int _redisCursor;

    public PoolLabService(
        DependencySettings dependencySettings,
        LabRunContext runContext,
        ILogger<PoolLabService> logger)
    {
        _dependencySettings = dependencySettings;
        _runContext = runContext;
        _logger = logger;

        if (runContext.Is("S21") || runContext.Is("S22"))
        {
            _configuredSize = runContext.Is("S21")
                ? PostgresLowPoolSize
                : PostgresHighPoolSize;
            _postgresDataSource = CreatePostgresDataSource(_configuredSize);
        }
        else if (runContext.Is("S23") || runContext.Is("S24"))
        {
            _configuredSize = runContext.Is("S23")
                ? RedisLowPoolSize
                : RedisHighPoolSize;
            _redisPool = new Lazy<Task<RedisPoolSlot[]>>(
                () => CreateRedisPoolAsync(_configuredSize),
                LazyThreadSafetyMode.ExecutionAndPublication);
        }
        else if (runContext.Is("S25") || runContext.Is("S26"))
        {
            _configuredSize = runContext.Is("S25")
                ? HttpLowPoolSize
                : HttpHighPoolSize;
            _httpClient = CreateHttpClient(_configuredSize);
        }
    }

    public async Task<PoolResult> ExercisePostgresAsync(CancellationToken cancellationToken)
    {
        EnsureScenario("S21", "S22");
        var dataSource = _postgresDataSource!;
        var tags = PoolTags("postgres", _configuredSize);
        var operationStopwatch = Stopwatch.StartNew();
        var waitStopwatch = Stopwatch.StartNew();
        NpgsqlConnection connection;

        try
        {
            connection = await dataSource.OpenConnectionAsync(cancellationToken);
        }
        catch (Exception exception) when (exception is NpgsqlException or TimeoutException)
        {
            waitStopwatch.Stop();
            LabTelemetry.PoolWaitDuration.Record(waitStopwatch.Elapsed.TotalMilliseconds, tags);
            LabTelemetry.PoolTimeouts.Add(1, tags);
            _logger.LogWarning(
                exception,
                "PostgreSQL pool acquisition failed after {WaitMs:F2} ms with configured size {PoolSize}",
                waitStopwatch.Elapsed.TotalMilliseconds,
                _configuredSize);
            throw;
        }

        waitStopwatch.Stop();
        LabTelemetry.PoolWaitDuration.Record(waitStopwatch.Elapsed.TotalMilliseconds, tags);
        LabTelemetry.PoolActiveLeases.Add(1, tags);

        var leaseStopwatch = Stopwatch.StartNew();
        try
        {
            await using (connection)
            await using (var command = connection.CreateCommand())
            {
                command.CommandText =
                    "SELECT count(*) FROM products WHERE category_id = 1 AND is_active";
                var scalar = await command.ExecuteScalarAsync(cancellationToken);

                // The same deterministic work is kept inside the lease in both pool-size
                // scenarios so the configured capacity, queueing, and fan-out are visible.
                await Task.Delay(100, cancellationToken);

                operationStopwatch.Stop();
                return new PoolResult(
                    "postgres",
                    _runContext.Is("S21") ? "bounded-low" : "bounded-high",
                    _configuredSize,
                    null,
                    Convert.ToInt32(scalar, CultureInfo.InvariantCulture),
                    operationStopwatch.Elapsed.TotalMilliseconds,
                    waitStopwatch.Elapsed.TotalMilliseconds);
            }
        }
        finally
        {
            leaseStopwatch.Stop();
            LabTelemetry.PoolLeaseDuration.Record(leaseStopwatch.Elapsed.TotalMilliseconds, tags);
            LabTelemetry.PoolActiveLeases.Add(-1, tags);
        }
    }

    public async Task<PoolResult> ExerciseRedisAsync(CancellationToken cancellationToken)
    {
        EnsureScenario("S23", "S24");
        var operationStopwatch = Stopwatch.StartNew();
        var pool = await _redisPool!.Value;
        var slotIndex = _runContext.Is("S23")
            ? 0
            : (int)((uint)Interlocked.Increment(ref _redisCursor) % (uint)pool.Length);
        var slot = pool[slotIndex];
        var tags = PoolTags("redis-multiplexer", _configuredSize);
        var waitStopwatch = Stopwatch.StartNew();

        await slot.Gate.WaitAsync(cancellationToken);
        waitStopwatch.Stop();
        LabTelemetry.PoolWaitDuration.Record(waitStopwatch.Elapsed.TotalMilliseconds, tags);
        LabTelemetry.PoolActiveLeases.Add(1, tags);

        var leaseStopwatch = Stopwatch.StartNew();
        try
        {
            var value = await slot.Multiplexer
                .GetDatabase()
                .StringIncrementAsync($"pool-lab:{_runContext.ScenarioId}:{slotIndex}");

            // Exclusively leasing a thread-safe multiplexer is intentional here: it
            // demonstrates why wrapping StackExchange.Redis in a conventional pool
            // creates either client-side queueing or excessive connections.
            await Task.Delay(75, cancellationToken);

            operationStopwatch.Stop();
            return new PoolResult(
                "redis",
                _runContext.Is("S23") ? "exclusive-pool-low" : "exclusive-pool-high",
                _configuredSize,
                pool.Length,
                checked((int)(value % int.MaxValue)),
                operationStopwatch.Elapsed.TotalMilliseconds,
                waitStopwatch.Elapsed.TotalMilliseconds);
        }
        finally
        {
            leaseStopwatch.Stop();
            LabTelemetry.PoolLeaseDuration.Record(leaseStopwatch.Elapsed.TotalMilliseconds, tags);
            LabTelemetry.PoolActiveLeases.Add(-1, tags);
            slot.Gate.Release();
        }
    }

    public async Task<PoolResult> ExerciseHttpAsync(CancellationToken cancellationToken)
    {
        EnsureScenario("S25", "S26");
        var tags = PoolTags("http", _configuredSize);
        var stopwatch = Stopwatch.StartNew();
        LabTelemetry.PoolActiveLeases.Add(1, tags);

        try
        {
            using var response = await _httpClient!.GetAsync(
                "/internal/pool-delay",
                HttpCompletionOption.ResponseHeadersRead,
                cancellationToken);
            response.EnsureSuccessStatusCode();

            stopwatch.Stop();
            LabTelemetry.PoolLeaseDuration.Record(stopwatch.Elapsed.TotalMilliseconds, tags);
            return new PoolResult(
                "http",
                _runContext.Is("S25") ? "max-connections-low" : "max-connections-high",
                _configuredSize,
                null,
                1,
                stopwatch.Elapsed.TotalMilliseconds,
                null);
        }
        finally
        {
            LabTelemetry.PoolActiveLeases.Add(-1, tags);
        }
    }

    private NpgsqlDataSource CreatePostgresDataSource(int poolSize)
    {
        var connectionString = new NpgsqlConnectionStringBuilder(_dependencySettings.PostgreSql)
        {
            ApplicationName = $"perflab-api-{_runContext.ScenarioId.ToLowerInvariant()}-pool",
            MaxPoolSize = poolSize,
            MinPoolSize = 0,
            Timeout = _runContext.Is("S21") ? 1 : 5
        };

        return NpgsqlDataSource.Create(connectionString.ConnectionString);
    }

    private async Task<RedisPoolSlot[]> CreateRedisPoolAsync(int poolSize)
    {
        var connectionTasks = Enumerable.Range(0, poolSize)
            .Select(async _ => new RedisPoolSlot(
                await ConnectionMultiplexer.ConnectAsync(_dependencySettings.Redis)))
            .ToArray();
        var pool = await Task.WhenAll(connectionTasks);

        LabTelemetry.PoolResourcesCreated.Add(
            pool.LongLength,
            PoolTags("redis-multiplexer", poolSize));
        _logger.LogInformation(
            "Created application-managed Redis multiplexer pool with {PoolSize} clients",
            poolSize);
        return pool;
    }

    private static HttpClient CreateHttpClient(int maximumConnections)
    {
        var handler = new SocketsHttpHandler
        {
            MaxConnectionsPerServer = maximumConnections,
            ConnectTimeout = TimeSpan.FromSeconds(2),
            PooledConnectionIdleTimeout = TimeSpan.FromMinutes(2),
            PooledConnectionLifetime = TimeSpan.FromMinutes(10)
        };

        return new HttpClient(handler, disposeHandler: true)
        {
            BaseAddress = new Uri("http://127.0.0.1:8080"),
            Timeout = TimeSpan.FromSeconds(5)
        };
    }

    private TagList PoolTags(string poolName, int configuredSize) =>
        LabTelemetry.Tags(
            _runContext.ScenarioId,
            _runContext.RunId,
            ("pool.name", poolName),
            ("pool.configured_size", configuredSize));

    private void EnsureScenario(string first, string second)
    {
        if (!_runContext.Is(first) && !_runContext.Is(second))
        {
            throw new InvalidOperationException(
                $"Endpoint is only available for scenarios {first} and {second}; current scenario is {_runContext.ScenarioId}.");
        }
    }

    public async ValueTask DisposeAsync()
    {
        if (_postgresDataSource is not null)
        {
            await _postgresDataSource.DisposeAsync();
        }

        if (_redisPool is { IsValueCreated: true })
        {
            foreach (var slot in await _redisPool.Value)
            {
                slot.Dispose();
            }
        }

        _httpClient?.Dispose();
    }

    private sealed class RedisPoolSlot(ConnectionMultiplexer multiplexer) : IDisposable
    {
        public ConnectionMultiplexer Multiplexer { get; } = multiplexer;
        public SemaphoreSlim Gate { get; } = new(1, 1);

        public void Dispose()
        {
            Gate.Dispose();
            Multiplexer.Dispose();
        }
    }
}
