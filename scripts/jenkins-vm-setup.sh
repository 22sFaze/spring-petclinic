#!/bin/bash
# Sets up a fresh Ubuntu 22.04 VM as the Jenkins server for the Spring PetClinic -> AKS pipeline.
# Installs: Java 17, Docker, Azure CLI, kubectl, Trivy, SonarQube (container), Jenkins (pre-configured).
# Secrets are passed as environment variables by the caller and are NOT stored in this repo:
#   SP_ID SP_SECRET TENANT_ID (Azure service principal)   ADMIN_PASS (Jenkins/Sonar admin password)
#   GIT_URL (app repo to build)
set -euxo pipefail
export DEBIAN_FRONTEND=noninteractive

: "${SP_ID:?}" "${SP_SECRET:?}" "${TENANT_ID:?}" "${ADMIN_PASS:?}" "${GIT_URL:?}"

echo "=== 1. Base packages, Java 17, Docker ==="
apt-get update
apt-get install -y openjdk-17-jdk docker.io curl wget git jq unzip gnupg lsb-release ca-certificates apt-transport-https
systemctl enable --now docker

echo "=== 2. Azure CLI + kubectl ==="
curl -sL https://aka.ms/InstallAzureCLIDeb | bash
az aks install-cli

echo "=== 3. Trivy ==="
wget -qO - https://aquasecurity.github.io/trivy-repo/deb/public.key | gpg --dearmor -o /usr/share/keyrings/trivy.gpg
echo "deb [signed-by=/usr/share/keyrings/trivy.gpg] https://aquasecurity.github.io/trivy-repo/deb generic main" > /etc/apt/sources.list.d/trivy.list
apt-get update
apt-get install -y trivy

echo "=== 4. SonarQube (container, localhost only) ==="
sysctl -w vm.max_map_count=524288
echo "vm.max_map_count=524288" > /etc/sysctl.d/99-sonarqube.conf
docker run -d --name sonarqube --restart unless-stopped \
  -p 127.0.0.1:9000:9000 \
  -v sonarqube_data:/opt/sonarqube/data \
  -v sonarqube_logs:/opt/sonarqube/logs \
  -v sonarqube_extensions:/opt/sonarqube/extensions \
  sonarqube:community

echo "Waiting for SonarQube to be UP..."
for i in $(seq 1 60); do
  if curl -s http://localhost:9000/api/system/status | grep -q '"status":"UP"'; then break; fi
  sleep 10
done
curl -s http://localhost:9000/api/system/status

SONAR_TOKEN=$(curl -s -u admin:admin -X POST "http://localhost:9000/api/user_tokens/generate" -d name=jenkins | jq -r .token)
test -n "$SONAR_TOKEN" && [ "$SONAR_TOKEN" != "null" ]
curl -s -u admin:admin -X POST "http://localhost:9000/api/users/change_password" \
  -d login=admin -d previousPassword=admin --data-urlencode "password=${ADMIN_PASS}" || true

echo "=== 5. Jenkins ==="
mkdir -p /usr/share/keyrings
wget -O /usr/share/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2026.key \
  || wget -O /usr/share/keyrings/jenkins-keyring.asc https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] https://pkg.jenkins.io/debian-stable binary/" > /etc/apt/sources.list.d/jenkins.list
apt-get update
apt-get install -y jenkins
systemctl stop jenkins
usermod -aG docker jenkins

echo "=== 6. Jenkins plugins ==="
wget -O /tmp/jpm.jar https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/2.13.2/jenkins-plugin-manager-2.13.2.jar \
  || wget -O /tmp/jpm.jar https://github.com/jenkinsci/plugin-installation-manager-tool/releases/download/2.13.0/jenkins-plugin-manager-2.13.0.jar
mkdir -p /var/lib/jenkins/plugins
java -jar /tmp/jpm.jar --war /usr/share/java/jenkins.war --plugin-download-directory /var/lib/jenkins/plugins \
  --plugins configuration-as-code job-dsl workflow-aggregator git sonar credentials-binding plain-credentials junit timestamper pipeline-stage-view ws-cleanup

echo "=== 7. Jenkins Configuration as Code ==="
mkdir -p /var/lib/jenkins/casc
cat > /var/lib/jenkins/casc/jenkins.yaml <<'EOF'
jenkins:
  systemMessage: "Project 5 - Spring PetClinic CI/CD to AKS"
  numExecutors: 2
  securityRealm:
    local:
      allowsSignup: false
      users:
        - id: "admin"
          password: "${ADMIN_PASS}"
  authorizationStrategy:
    loggedInUsersCanDoAnything:
      allowAnonymousRead: false
credentials:
  system:
    domainCredentials:
      - credentials:
          - usernamePassword:
              scope: GLOBAL
              id: "acr-credentials"
              description: "ACR login (service principal)"
              username: "${SP_ID}"
              password: "${SP_SECRET}"
          - usernamePassword:
              scope: GLOBAL
              id: "azure-sp"
              description: "Azure service principal"
              username: "${SP_ID}"
              password: "${SP_SECRET}"
          - string:
              scope: GLOBAL
              id: "azure-tenant-id"
              description: "Azure tenant ID"
              secret: "${TENANT_ID}"
          - string:
              scope: GLOBAL
              id: "sonar-token"
              description: "SonarQube token"
              secret: "${SONAR_TOKEN}"
unclassified:
  sonarGlobalConfiguration:
    installations:
      - name: "SonarQube"
        serverUrl: "http://localhost:9000"
        credentialsId: "sonar-token"
jobs:
  - script: >
      pipelineJob('spring-petclinic') {
        definition {
          cpsScm {
            scm {
              git {
                remote { url('${GIT_URL}') }
                branches('*/main')
              }
            }
            scriptPath('Jenkinsfile')
          }
        }
      }
EOF

mkdir -p /etc/systemd/system/jenkins.service.d
cat > /etc/systemd/system/jenkins.service.d/override.conf <<EOF
[Service]
Environment="JAVA_OPTS=-Djava.awt.headless=true -Djenkins.install.runSetupWizard=false"
Environment="CASC_JENKINS_CONFIG=/var/lib/jenkins/casc/jenkins.yaml"
Environment="ADMIN_PASS=${ADMIN_PASS}"
Environment="SP_ID=${SP_ID}"
Environment="SP_SECRET=${SP_SECRET}"
Environment="TENANT_ID=${TENANT_ID}"
Environment="SONAR_TOKEN=${SONAR_TOKEN}"
Environment="GIT_URL=${GIT_URL}"
EOF
chmod 600 /etc/systemd/system/jenkins.service.d/override.conf
chown -R jenkins:jenkins /var/lib/jenkins
systemctl daemon-reload
systemctl enable --now jenkins

for i in $(seq 1 30); do
  code=$(curl -s -o /dev/null -w '%{http_code}' http://localhost:8080/login || true)
  [ "$code" = "200" ] && break
  sleep 5
done
echo "Jenkins HTTP status: $code"
echo "SETUP_COMPLETE"
