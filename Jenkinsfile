pipeline {
    agent any

    parameters {
        string(name: 'REGISTRY_URL',       defaultValue: 'your-registry.azurecr.io', description: 'ACR login server')
        string(name: 'AKS_RESOURCE_GROUP', defaultValue: 'your-rg',                 description: 'AKS resource group')
        string(name: 'AKS_CLUSTER_NAME',   defaultValue: 'your-aks',                description: 'AKS cluster name')
        string(name: 'AZURE_TENANT_ID',    defaultValue: '',                        description: 'Azure tenant ID')
    }

    environment {
        APP_NAME  = 'spring-petclinic'
        IMAGE_TAG = "${env.BUILD_NUMBER}"
        IMAGE     = "${params.REGISTRY_URL}/spring-petclinic:${env.BUILD_NUMBER}"
        NAMESPACE = 'petclinic'
    }

    options {
        buildDiscarder(logRotator(numToKeepStr: '20'))
        timeout(time: 60, unit: 'MINUTES')
        timestamps()
    }

    stages {
        stage('Checkout') {
            steps { checkout scm }
        }

        stage('Validate tools') {
            steps {
                sh 'java -version && docker --version && az version >/dev/null && kubectl version --client && trivy --version'
            }
        }

        stage('Build & Test') {
            steps { sh './mvnw -B clean verify' }
            post { always { junit allowEmptyResults: true, testResults: 'target/surefire-reports/*.xml' } }
        }

        stage('SonarQube') {
            steps {
                withSonarQubeEnv('SonarQube') {
                    sh "./mvnw -B sonar:sonar -Dsonar.projectKey=${APP_NAME} -Dsonar.projectName=${APP_NAME}"
                }
                timeout(time: 5, unit: 'MINUTES') { waitForQualityGate abortPipeline: true }
            }
        }

        stage('Docker Build') {
            steps { sh 'docker build -t ${IMAGE} .' }
        }

        stage('Trivy Scan') {
            steps {
                // Report everything HIGH+, but fail the build only on CRITICAL
                sh 'trivy image --severity HIGH,CRITICAL --format table ${IMAGE}'
                sh 'trivy image --severity CRITICAL --exit-code 1 --ignore-unfixed ${IMAGE}'
            }
        }

        stage('Push to ACR') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'acr-credentials',
                                                  usernameVariable: 'ACR_USER', passwordVariable: 'ACR_PASS')]) {
                    sh '''
                        echo "$ACR_PASS" | docker login "${REGISTRY_URL}" -u "$ACR_USER" --password-stdin
                        docker push ${IMAGE}
                        docker tag ${IMAGE} ${REGISTRY_URL}/${APP_NAME}:latest
                        docker push ${REGISTRY_URL}/${APP_NAME}:latest
                        docker logout "${REGISTRY_URL}"
                    '''
                }
            }
        }

        stage('Deploy to AKS') {
            steps {
                withCredentials([usernamePassword(credentialsId: 'azure-sp',
                                                  usernameVariable: 'AZ_CLIENT_ID', passwordVariable: 'AZ_CLIENT_SECRET')]) {
                    sh '''
                        az login --service-principal -u "$AZ_CLIENT_ID" -p "$AZ_CLIENT_SECRET" --tenant "${AZURE_TENANT_ID}" >/dev/null
                        az aks get-credentials --resource-group "${AKS_RESOURCE_GROUP}" --name "${AKS_CLUSTER_NAME}" --overwrite-existing

                        kubectl create namespace ${NAMESPACE} --dry-run=client -o yaml | kubectl apply -f -
                        sed "s|IMAGE_PLACEHOLDER|${IMAGE}|" k8s/deployment.yaml | kubectl apply -n ${NAMESPACE} -f -
                        kubectl apply -n ${NAMESPACE} -f k8s/service.yaml
                        kubectl rollout status deployment/${APP_NAME} -n ${NAMESPACE} --timeout=5m
                        kubectl get svc ${APP_NAME} -n ${NAMESPACE}
                    '''
                }
            }
        }

        stage('Smoke Test') {
            steps {
                sh '''
                    kubectl port-forward svc/${APP_NAME} 18080:80 -n ${NAMESPACE} >/dev/null 2>&1 &
                    PF=$!
                    sleep 5
                    ok=0
                    for i in 1 2 3 4 5; do
                        if curl -fs http://localhost:18080/actuator/health | grep -q UP; then ok=1; break; fi
                        sleep 10
                    done
                    kill $PF || true
                    [ "$ok" = "1" ] || { echo "Smoke test failed"; exit 1; }
                    echo "Smoke test passed"
                '''
            }
        }
    }

    post {
        always  { archiveArtifacts artifacts: 'target/*.jar', allowEmptyArchive: true }
        success { echo "Deployed ${IMAGE} to ${AKS_CLUSTER_NAME}/${NAMESPACE}" }
        failure { echo "Pipeline failed at stage: ${env.STAGE_NAME}" }
    }
}
