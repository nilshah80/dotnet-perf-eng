using Microsoft.EntityFrameworkCore;
using PerfLab.Api.Contracts;
using PerfLab.Shared.Configuration;
using PerfLab.Shared.Data;
using PerfLab.Shared.Diagnostics;

namespace PerfLab.Api.Services;

public sealed class CatalogService(
    IDbContextFactory<LabDbContext> contextFactory,
    LabRunContext runContext)
{
    public async Task<IReadOnlyList<ProductResult>> GetRecommendationsAsync(
        int categoryId,
        int take,
        CancellationToken cancellationToken)
    {
        var tags = LabTelemetry.Tags(runContext.ScenarioId, runContext.RunId);
        LabTelemetry.ScenarioExecutions.Add(1, tags);

        using var activity = LabTelemetry.ActivitySource.StartActivity("catalog.recommendations");
        activity?.SetTag("scenario.id", runContext.ScenarioId);
        activity?.SetTag("catalog.category_id", categoryId);

        await using var db = await contextFactory.CreateDbContextAsync(cancellationToken);
        var candidateLimit = runContext.Is("S01") ? 2_500 : Math.Max(take * 5, 100);
        var candidates = await db.Products
            .AsNoTracking()
            .Where(x => x.CategoryId == categoryId && x.IsActive)
            .OrderBy(x => x.Id)
            .Take(candidateLimit)
            .Select(x => new Candidate(x.Id, x.Name, x.SearchText, x.Price))
            .ToListAsync(cancellationToken);

        IReadOnlyList<ProductResult> result;
        if (runContext.Is("S01"))
        {
            var ranked = new List<ProductResult>(candidates.Count);
            foreach (var candidate in candidates)
            {
                var score = 0d;
                foreach (var comparison in candidates)
                {
                    var distance = Math.Abs(candidate.Id - comparison.Id);
                    if ((distance % 17) == 0)
                    {
                        score += 1d / (distance + 1);
                    }

                    if (candidate.SearchText.AsSpan().SequenceEqual(comparison.SearchText))
                    {
                        score += 0.001;
                    }
                }

                ranked.Add(new ProductResult(candidate.Id, candidate.Name, candidate.Price, score));
            }

            result = ranked
                .OrderByDescending(x => x.Score)
                .ThenBy(x => x.Id)
                .Take(take)
                .ToArray();
        }
        else
        {
            result = candidates
                .OrderBy(x => x.Price)
                .ThenBy(x => x.Id)
                .Take(take)
                .Select(x => new ProductResult(x.Id, x.Name, x.Price, 1d / ((double)x.Price + 1d)))
                .ToArray();
        }

        LabTelemetry.ResponseItems.Record(result.Count, tags);
        return result;
    }

    private sealed record Candidate(int Id, string Name, string SearchText, decimal Price);
}
