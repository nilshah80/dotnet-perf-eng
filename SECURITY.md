# Security policy

## Supported versions

This repository is a performance-engineering harness and reference lab. It is
developed on `main`; there is no long-term support branch. Security fixes land
on `main` and are described in [`CHANGELOG.md`](CHANGELOG.md).

## Reporting a vulnerability

**Please do not open a public issue for a security problem.**

Report it through GitHub's private vulnerability reporting instead:

1. Go to the [Security tab](https://github.com/nilshah80/dotnet-perf-eng/security).
2. Choose **Report a vulnerability**.
3. Describe the issue, the affected paths, and how to reproduce it.

The report stays private between you and the maintainer until a fix is
published. Expect an acknowledgement within 7 days.

## Scope

This repository ships a **deliberately vulnerable-by-design performance lab**.
The reference application under [`source/`](source/) and the labs under
[`labs/`](labs/) contain *intentionally planted defects* — N+1 queries, unbounded
allocation, lock contention, missing indexes and similar — because reproducing
them is the entire point of the lab.

Those planted defects are **not** security vulnerabilities and are out of scope.

In scope:

- credentials, tokens or private data committed to the repository;
- harness scripts that execute untrusted input, escape their working directory,
  or write outside the evidence tree;
- container or Compose definitions that expose a service beyond loopback, or
  that run with more privilege than the lab requires;
- anything in [`harness/`](harness/) that could affect a host running the lab.

## Running the lab safely

Every service binds to loopback by default and the lab is designed for
single-operator local use. Do not expose the Compose stacks to a shared network
or run them against production systems. The default credentials in the Compose
files are lab credentials and must never be reused elsewhere.
