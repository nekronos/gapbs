# Reference documentation

Vendor documentation is **not committed** — this is a public fork, and the
optimization guides are copyrighted material that may not be redistributed.
`docs/.gitignore` keeps PDFs local. Fetch them yourself and drop them here.

## Target microarchitecture: AMD Zen 5

| Document | ID | Where |
| --- | --- | --- |
| Software Optimization Guide for the AMD Zen5 Microarchitecture | 58455 rev 1.00, Aug 2024 | <https://docs.amd.com/v/u/en-US/58455_1.00> |

The page is a JavaScript portal, so `curl` returns the viewer shell rather than
the document. Open it in a browser and save as `docs/58455_zen5_sog.pdf`.

Worth having alongside it:

| Document | ID |
| --- | --- |
| AMD64 Architecture Programmer's Manual | 24593 / 26568 |
| Processor Programming Reference (PPR) for the specific Zen 5 model | per-model |
| AMD uProf (profiling, PMC event reference) | — |

The PPR is what defines the performance counter names this harness needs on
AMD — see `bench/WORKFLOW.md`, "Counters differ by vendor".
