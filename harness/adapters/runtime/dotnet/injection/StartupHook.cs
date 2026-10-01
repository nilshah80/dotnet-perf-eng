using System.Runtime.Loader;
using PerfLab.DotNet.Injection;

/// <summary>
/// The DOTNET_STARTUP_HOOKS entry point; the runtime calls Initialize before the
/// application's Main. It must stay in the global namespace with this name.
/// </summary>
internal static class StartupHook
{
    public static void Initialize()
    {
        // The hook's dependencies ship beside it, outside the application's
        // probing paths. The application's own copies still win: this handler
        // runs only when the default context cannot find an assembly.
        var directory = Path.GetDirectoryName(typeof(StartupHook).Assembly.Location)!;
        AssemblyLoadContext.Default.Resolving += (context, name) =>
        {
            var candidate = Path.Combine(directory, name.Name + ".dll");
            return File.Exists(candidate) ? context.LoadFromAssemblyPath(candidate) : null;
        };

        // Kept in a separate method so the Pyroscope types load only after the
        // handler above is registered.
        SpanProfiles.Start();
    }
}
