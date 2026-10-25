# Contributing to the performance-engineering lab

Thanks for your interest. This harness is a ports-and-adapters toolkit: a
stable core drives measurement, evidence capture, normalization and a read-only
AI diagnosis, and everything project- or language-specific plugs in through a
bash descriptor and small adapter scripts.

## The one rule that shapes everything

**Onboarding a project or runtime means adding files, not editing the core.**

If a change requires editing [`harness/core/`](harness/core/) to support one
project, that is a signal the port is wrong — the missing capability probably
belongs in a descriptor field or an adapter hook. Raise it as an issue before
writing the patch. Architecture, contracts and the per-runtime adapter matrix
are in [`BLUEPRINT.md`](BLUEPRINT.md).

## Prerequisites

| Tool | Why |
|---|---|
| Docker + Compose | every lab service; nothing runs in the cloud |
| .NET SDK 10 | the reference API and order worker under [`source/`](source/) |
| bash, Python 3 | the harness itself and the contract checks; Python is found as `python3` or `python` |
| jq 1.7+ | the contract checks' tests; the harness itself runs jq in Docker unless `PERFLAB_JQ=host` |
| k6 (default), optionally wrk | load generation; JMeter runs container-only |

The contract checks also expect the PerfLab repository checked out beside this
one, as `../perflab`: the plan-consistency check reads its files.

**Windows.** Run the gate from Git Bash; Git for Windows supplies bash and the
POSIX tools. Python must be a real interpreter: the `python3.exe` App
Execution Alias only prints a Microsoft Store advert, so install Python from
python.org or winget, or turn the Python aliases off in Settings. Install jq on
the host as well, for example with `winget install jqlang.jq`.

## Single-operator constraint

The labs publish the **same loopback ports** and each uses a single Compose
project, so **two harness invocations at once are unsupported**. A second run
recreates the app containers under a different scenario mid-measurement and
corrupts both sets of results. Run one scenario, suite or sweep at a time. The
harness stops the other lab's stack automatically on bring-up.

This is not a limitation to work around in a pull request — it is a deliberate
design constraint that keeps a measurement attributable to one configuration.

## The check gate

```sh
./scripts/contract/check.sh
```

This runs the contract, markdown and plan-consistency checks, plus the
independence check that keeps the harness core free of project-specific
assumptions.

Do not commit evidence output. Runs land under the artifacts tree and are
ignored; [`perf-history/`](perf-history/) holds only curated, reviewed results.

## Planted defects are intentional

The reference project is a .NET 10 service with **deliberately planted
performance defects**. Do not "fix" one in [`source/`](source/) or
[`labs/`](labs/) unless the issue explicitly asks for it — reproducing those
defects is what the lab measures. A planted defect is documented as such; if you
find one that is not documented, open an issue rather than a patch.

Genuine bugs *in the harness* are of course welcome.

## Contract parity

The implementation plan is **byte-identical** in this repository and in
[`perflab`](https://github.com/nilshah80/perflab). Each side validates its own
[`parity-lock.json`](parity-lock.json) locally; cross-repository equality is
decided only by the release coordinator comparing exported attestations.

```sh
./scripts/contract/verify-lock.sh --attest <path>
```

The attestation emits only after the lock, manifest and contract-file digests
pass. This repository owns no Go — never invoke the sibling repository's Go
tooling here. Two independent implementations agreeing is the point. If you
change a contract document, change it identically on both sides in the same
logical change, and say so in the pull request.

## Commits and pull requests

- Branch from `main`; keep one logical change per pull request.
- Write commit subjects in the imperative mood ("Add Redis dependency probe").
- Say whether the change touches the core, an adapter, a lab, or a contract
  document — and if it touches the core, why an adapter could not carry it.
- Confirm `./scripts/contract/check.sh` passes locally.

## Licensing of contributions

This project is licensed under [Apache-2.0](LICENSE). By contributing, you agree
that your contributions are licensed under the same terms, per section 5 of that
license.
