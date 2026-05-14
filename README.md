# Workload Partitioning Day-2 Configuration

**IMPORTANT**: All the work in this repo is not endorsed or supported in any way by Red Hat. **Use at your own risk**. Enabling workload partitioning is only supported at deployment time. [READ THIS](https://docs.redhat.com/en/documentation/openshift_container_platform/4.20/html-single/scalability_and_performance/index#enabling-workload-partitioning_enabling-workload-partitioning).

----

**Non-supported** procedure to enable workload partitioning in OpenShift as a day 2 operation. This **must not** be used in production environments. Keep in mind that the procedure only implements the _happy path_, if things go wrong there is no recovery plan. **Recovery plan is full cluster re-deployment**.

TL;DR: Make sure you're logged as `cluster-admin` in your OCP cluster and run [scripts/patch-infra.sh](scripts/patch-infra.sh).

- **[TEST-PLAN.md](TEST-PLAN.md)** -- Test cases, sequencing, and the critical ordering constraint.
- **[REPORT.md](REPORT.md)** -- Results and conclusions.
- **[scripts/](scripts/)** -- Scripts used for the test.
- **[manifests/](manifests/)** -- Relevant manifests for the test.
- **[tools/gomaxprocs-check](tools/gomaxprocs-check/)** -- Utility to check GOMAXPROCS inside a container.
