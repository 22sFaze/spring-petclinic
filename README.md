# Spring PetClinic: CI/CD Pipeline to Azure Kubernetes Service

**Project 5, Azure Cloud Engineering.** A complete Jenkins pipeline that builds, tests, scans and deploys the
[Spring PetClinic](https://github.com/spring-projects/spring-petclinic) sample application to Azure Kubernetes Service (AKS).

> The original upstream README is kept as [README-upstream.md](README-upstream.md).

## Architecture

```
GitHub (this repo)
      |
      v
Jenkins on an Azure VM  ->  Maven build + tests  ->  SonarQube analysis  ->  Docker build
      |                                                                          |
      |                                       Trivy scan (fails on fixable CRITICAL CVEs)
      |                                                                          |
      v                                                                          v
Azure Container Registry (ACR)  <-------------------------------------  push image
      |
      v
Azure Kubernetes Service (AKS)  ->  LoadBalancer  ->  smoke test on /actuator/health
```

## Pipeline stages (`Jenkinsfile`)

| Stage | What it does | Why |
|---|---|---|
| Checkout | Clones this repository | Source of truth |
| Validate tools | Checks Java, Docker, Azure CLI, kubectl, Trivy | Fails fast if the build server is misconfigured |
| Build & Test | `./mvnw clean verify` (81 tests) | Proves the code compiles and works, including Postgres integration tests |
| SonarQube | Static analysis and quality gate | Catches bugs and code smells; reported as UNSTABLE if the gate fails |
| Docker Build | Multi-stage Dockerfile, Java 17, non-root user | Small, reproducible runtime image |
| Trivy Scan | Scans the image; **fails the build on fixable CRITICAL vulnerabilities** | Security gate before anything is published |
| Push to ACR | Pushes `:<build number>` and `:latest` | Versioned, traceable images |
| Deploy to AKS | Applies `k8s/deployment.yaml` and `k8s/service.yaml`, waits for rollout | Automated delivery |
| Smoke Test | Port-forwards to the service and checks `/actuator/health` | Confirms the deployed app is healthy |

## What is in this repository (added on top of upstream)

| Path | Purpose |
|---|---|
| `Jenkinsfile` | The declarative pipeline |
| `Dockerfile` | Multi-stage build (Maven on Java 17, then a slim JRE image) |
| `k8s/deployment.yaml`, `k8s/service.yaml` | Kubernetes manifests (2 replicas, probes, resource limits, LoadBalancer) |
| `scripts/jenkins-vm-setup.sh` | Turns a fresh Ubuntu 22.04 VM into the Jenkins server |
| `pom.xml` | Dependency overrides that fix the CVEs Trivy reported (see below) |

## Azure resources

Everything lives in one resource group so it can be removed in one command.

| Resource | Name | Notes |
|---|---|---|
| Resource group | `petclinic-rg` | Canada Central |
| Container registry | `petclinicacrfaiz123` | Basic SKU |
| AKS cluster | `petclinic-aks` | 2 nodes, `Standard_D2s_v3`, registry attached |
| Jenkins VM | `jenkins-vm` | Ubuntu 22.04, `Standard_D2s_v3`, port 8080 open |
| Service principal | `petclinic-jenkins-sp` | Contributor on the resource group, AcrPush on the registry |

## Setting it up

1. Create the resource group, ACR and AKS cluster (`az group create`, `az acr create`, `az aks create --attach-acr`).
2. Create a service principal scoped to the resource group and grant it `AcrPush` on the registry.
3. Create the Jenkins VM and open port 8080.
4. Run `scripts/jenkins-vm-setup.sh` on the VM with these environment variables (never commit them):
   `SP_ID`, `SP_SECRET`, `TENANT_ID`, `ADMIN_PASS`, `GIT_URL`.
   It installs everything and pre-configures Jenkins with credentials, the SonarQube connection and the pipeline job.
5. Open Jenkins on port 8080, sign in as `admin`, and run **Build with Parameters**.

Secrets are stored as Jenkins credentials (`acr-credentials`, `azure-sp`, `azure-tenant-id`, `sonar-token`) and are
never written into the repository.

## Problems found and fixed

These came up while getting the pipeline to green, and each one is a real-world lesson.

1. **Jenkins would not start.** The current Jenkins LTS requires Java 21 and refuses to run on Java 17.
   The VM runs Jenkins on Java 21 while the application is still built with Java 17 inside Docker.
2. **Two integration tests failed.** `PostgresIntegrationTests` start a database through `docker compose`,
   which the Ubuntu Docker package does not include. Installing the Compose plugin fixed it (81/81 tests pass).
3. **Trivy blocked the first deployments.** The image contained fixable CRITICAL vulnerabilities in application
   libraries: Apache Tomcat (`tomcat-embed-core` 11.0.22) and Spring Framework (`spring-webmvc` 7.0.8), plus a PostgreSQL
   driver issue. They were fixed by overriding the managed versions in `pom.xml`
   (`tomcat.version=11.0.25`, `spring-framework.version=7.0.9`, `postgresql.version=42.7.12`).
   The gate then passed. This is the pipeline doing its job.
4. **Short Sonar plugin name did not resolve.** The pipeline uses the full coordinates
   `org.sonarsource.scanner.maven:sonar-maven-plugin:sonar`.
5. **Credentials were handled safely.** The tenant ID, service principal and tokens come from Jenkins credentials,
   not from the repository or job parameters.

## Known limitations

- The SonarQube quality gate is report-only, so a failed gate marks the build UNSTABLE but does not stop the deploy.
- Some HIGH severity findings (for example in Jackson) remain; only CRITICAL findings fail the build.
- Jenkins is exposed on port 8080 without TLS. Fine for a lab, not for production.
- The database is the in-memory H2 default. A production setup would use Azure Database for PostgreSQL.

## Clean up

```bash
az group delete -n petclinic-rg --yes --no-wait
```

This removes the cluster, registry and VM, and stops all charges.
