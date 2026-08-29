Implement the minimal correction from the selected structured diagnosis.

Before editing, verify the diagnosis against the raw evidence and current source. Preserve endpoint contracts, response correctness, database/message semantics, scenario selection, telemetry, and safety limits. Do not hide the symptom by reducing concurrency, reducing data, adding sleeps, swallowing errors, or disabling instrumentation.

After editing:

1. Build the solution using the project's build command (provided at the end of this prompt), in Release configuration.
2. Explain each changed source location and why it breaks the diagnosed causal chain.
3. State any correctness or regression risk.
4. Do not claim a performance win until the same benchmark protocol is rerun and compared.

