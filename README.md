# Limina Helm Chart

This helm chart simplifies the deployment of the Limina product into your kubernetes environment.

Please keep in mind that for deployments requiring a public facing endpoint, you will need to provide your own certificate / deployment configurations.

## Prerequisites

- You must have a valid Limina license file and docker credentials. You can retrieve these from the Limina [Customer Portal](https://portal.getlimina.ai). If you have any issues, please [contact us](https://www.getlimina.ai/en/contact-us)
- You must have an existing kubernetes cluster
- Helm version 4.0.0 or greater

## Quickstart

To install the Limina chart, follow the steps below

```console
# Create a namespace in your cluster for the limina deployments
kubectl create namespace limina

# Create a secret with your docker credentials from the customer portal
kubectl -n limina create secret docker-registry crprivateaiprod-creds \
  --docker-server=crprivateaiprod.azurecr.io \
  --docker-username=USERNAME \
  --docker-password=PASSWORD

# Login to the helm registry with your docker credentials
helm registry login crprivateaiprod.azurecr.io

# Create a custom values file for your specific installation
helm show values oci://crprivateaiprod.azurecr.io/helm/limina:0.2.0 > "$(date +%Y%m%d).values.yaml"

# Copy your license.json file contents and paste them into the core.license.data section of the custom values.yaml file with single quotes surrounding, as per below
core:
  license:
    data: '{"id":"1", "tier": "..."}'

# By default, the Limina core pod is only scheduled onto nodes labelled container=limina-core
# Label the node(s) that should run Limina core (one core pod is scheduled per labelled node)
kubectl get nodes
kubectl label node NODE_NAME container=limina-core
# Alternatively, to allow Limina core to run on any node, set the following in your custom values file
core:
  deployment:
    nodeSelector: {}

# Install the limina chart with a name and namespace of limina
helm upgrade --install \
  limina oci://crprivateaiprod.azurecr.io/helm/limina \
  --namespace limina \
  -f "$(date +%Y%m%d).values.yaml" \
  --version 0.2.0
```

## Testing

To test the Limina container is functional, follow the steps below.

```console
helm test --namespace limina limina
```

## Uninstall

To uninstall the Limina container, follow the steps below.

```console
helm uninstall --namespace limina limina
```

## Additional Configuration
To customize your deployment, enable different sections of your values.yaml file as per the documentation below.

The values file is organized by product. Settings that apply to the whole chart sit at the top level, and each product has its own section:

```yaml
cloudProvider: "AWS"          # Global settings
nameOverride: ""
fullnameOverride: ""
repository: "crprivateaiprod.azurecr.io"
imagePullSecrets: {}

core: {}                      # Limina core, always deployed

async:                        # Async File Support
  shared: {}                  # Settings shared by the async components, including async.shared.enabled
  api: {}
  custodian: {}
  processor: {}

platform:                     # Limina Platform
  shared: {}                  # Settings shared by the platform components, including platform.shared.enabled
  middleware: {}
  ui: {}
  worker: {}

externalSecrets:              # External Secrets Operator settings, nested by product
  secretStoreName: "limina-store"
  secretStore: {}             # Optionally create the SecretStore with this chart
  dockerCredential: {}
  core:
    enabled: false
    license: {}
    env: {}
    tls: {}
  async:
    enabled: false
    shared: {}
    api: {}
  platform:
    enabled: false
    shared: {}
    ui: {}
```

### Enable GPU
In order to enable GPU processing, it is recommended that you first deploy a gpu-enabled node to your cluster with a taint, such as `dedicated=gpu:NoSchedule`

Once the node is available, update the following sections in your customized values file
```yaml
core:
  deployment:
    gpu:
      sizeLimit: "4Gi"
      limits:
        nvidia.com/gpu: 1
      tolerations:
        values:
          - key: "dedicated"
            operator: "Equal"
            value: "gpu"
            effect: "NoSchedule"
    image:
      tag: "4.5.1.2-gpu" # or "4.5.1.2-gpu-text"
```

Proceed with installing limina via helm into the limina namespace
```console
helm upgrade --install \
  limina oci://crprivateaiprod.azurecr.io/helm/limina \
  --namespace limina \
  -f "$(date +%Y%m%d).values.yaml" \
  --version 0.2.0
```


### Async File Support
Async File Support adds an additional set of containers to your cluster that will simplify managing both large (or complex) files, as well as large numbers of files. You can read more about the architecture [here](https://docs.getlimina.ai).

Prerequisites:
- Your kubernetes cluster must have a CSI driver that allows multiple pods read/write access to the same file system
- You must deploy a redis cluster to allow for queuing of requests
- You must ensure your kubernetes cluster has access to both redis and your file system

Steps:
- Update the following sections in your customized values file
```yaml
async:
  shared:
    enabled: true
    secrets:
      data:
        - name: "REDIS_KEY"
          value: "enter_redis_key" # Enter redis key here if you do not plan to use the External Secrets Operator
    pvc:
      storage: "200Gi" # Customize temporary file storage for async request and response objects
    storageClass: # Add details for your specific environment
    configmap:
      data:
        - name: "REDIS_HOST"
          value: "enter_redis_host" # Enter the redis host so that the async components can access the job queue
        - name: "REDIS_PORT"
          value: 6380 # Enter your redis port
        - name: "REDIS_ENABLE_SSL"
          value: "true" # Control whether or not to connect to redis via TLS
externalSecrets:
  async:
    enabled: false # Set to true to read the redis key from your secret store instead
    shared:
      env:
        remoteRefKey: "limina-shared" # The secret in your secret store containing the redis key
```

- Proceed with installing limina via helm into the limina namespace
```console
helm upgrade --install \
  limina oci://crprivateaiprod.azurecr.io/helm/limina \
  --namespace limina \
  -f "$(date +%Y%m%d).values.yaml" \
  --version 0.2.0
```


### Limina Platform
The Limina Platform adds a web ui, a middleware api and a pool of background workers on top of Limina core. The platform is independent of Async File Support.

When enabled, the chart deploys:
- **middleware**: the platform api. Database migrations run as an init container before it starts (`platform.middleware.migrations`)
- **worker**: background workers that process jobs from redis and call Limina core
- **ui**: the web application, which talks to the middleware. This is the component you expose to users via an ingress
- A shared persistent volume claim mounted by the middleware and worker, a shared configmap and secret, and an optional service account

The chart sets `LIMINA_CORE_URL`, `STORAGE_PATH` and `MIDDLEWARE_URL` for you, so the components find each other without extra configuration.

Prerequisites:
- Your kubernetes cluster must have a CSI driver that allows multiple pods read/write access to the same file system
- You must deploy a redis instance for job queuing, and a PostgreSQL database for platform data
- You must ensure your kubernetes cluster has access to redis, PostgreSQL and your file system
- You must configure an identity provider for user sign-in (e.g. a Google OAuth client)

Steps:
- Update the following sections in your customized values file
```yaml
platform:
  shared:
    enabled: true
    configmap:
      data:
        - name: "REDIS_HOST"
          value: "enter_redis_host"
        - name: "REDIS_PORT"
          value: 6379
        - name: "REDIS_SSL"
          value: "true"
        - name: "POSTGRES_HOST"
          value: "enter_postgres_host"
        - name: "POSTGRES_PORT"
          value: 5432
        - name: "POSTGRES_DB"
          value: "platform"
    secrets:
      data: # Ignored if you use the External Secrets Operator
        - name: "REDIS_PASSWORD"
          value: "enter_redis_password"
        - name: "POSTGRES_USER"
          value: "enter_postgres_user"
        - name: "POSTGRES_PASSWORD"
          value: "enter_postgres_password"
    pvc:
      storage: "100Gi" # Customize file storage for the platform
    storageClass: # Add details for your specific environment
  middleware:
    configmap:
      data:
        - name: "AUTH_PROVIDERS"
          value: '[{"name": "google", "issuer": "https://accounts.google.com", "audience": "enter_google_client_id"}]'
  ui:
    configmap:
      data:
        - name: "LIMINA_MODE"
          value: "PLATFORM"
        - name: "BETTER_AUTH_URL"
          value: "https://platform.ingress.domain.com" # The external URL of the ui
    secrets:
      data: # Ignored if you use the External Secrets Operator
        - name: "BETTER_AUTH_SECRET"
          value: "enter_a_long_random_string"
        - name: "GOOGLE_CLIENT_ID"
          value: "enter_google_client_id"
        - name: "GOOGLE_CLIENT_SECRET"
          value: "enter_google_client_secret"
    ingress:
      enabled: true
      host: "platform.ingress.domain.com"
```

- If you use the External Secrets Operator, set `externalSecrets.platform.enabled` to true. The platform and ui secrets are then read from `externalSecrets.platform.shared.env.remoteRefKey` and `externalSecrets.platform.ui.env.remoteRefKey`. By default the chart pulls the properties listed below from each remote secret. Update each `property` to match the property names in your secret store, or set `properties` to `[]` to add every property of the remote secret instead. Listing properties also lets both components share a single remote secret. To read a property from a different remote secret, set `remoteRefKey` on that property. For example, the database credentials below come from the secret that AWS RDS manages for the master user, and the redis password from the shared remote secret
```yaml
externalSecrets:
  platform:
    enabled: true
    shared:
      env:
        remoteRefKey: "limina-platform-env"
        properties:
          - secretKey: "REDIS_PASSWORD"
          - secretKey: "POSTGRES_USER"
            remoteRefKey: "rds!db-00000000-0000-0000-0000-000000000000"
            property: "username"
          - secretKey: "POSTGRES_PASSWORD"
            remoteRefKey: "rds!db-00000000-0000-0000-0000-000000000000"
            property: "password"
    ui:
      env:
        remoteRefKey: "limina-platform-env"
        properties:
          - secretKey: "BETTER_AUTH_SECRET"
          - secretKey: "GOOGLE_CLIENT_ID"
          - secretKey: "GOOGLE_CLIENT_SECRET"
```

- If the platform needs cloud permissions (e.g. AWS IRSA or Azure Workload Identity), create a service account for it
```yaml
platform:
  shared:
    serviceAccount:
      create: true
      annotations:
        eks.amazonaws.com/role-arn: "arn:aws:iam::111122223333:role/limina-platform"
```

- On AWS, you can expose the ui through the AWS Load Balancer Controller with an ACM certificate instead of haproxy and cert-manager
```yaml
platform:
  ui:
    ingress:
      enabled: true
      ingressClassName: "alb"
      selfsigned: false
      host: "platform.ingress.domain.com"
      annotations:
        alb.ingress.kubernetes.io/scheme: "internet-facing"
        alb.ingress.kubernetes.io/target-type: "ip"
        alb.ingress.kubernetes.io/listen-ports: '[{"HTTP":80},{"HTTPS":443}]'
        alb.ingress.kubernetes.io/ssl-redirect: "443"
        alb.ingress.kubernetes.io/certificate-arn: "arn:aws:acm:region:111122223333:certificate/certificate-id"
        alb.ingress.kubernetes.io/healthcheck-path: "/healthz"
```

- Proceed with installing limina via helm into the limina namespace
```console
helm upgrade --install \
  limina oci://crprivateaiprod.azurecr.io/helm/limina \
  --namespace limina \
  -f "$(date +%Y%m%d).values.yaml" \
  --version 0.2.0
```


### Ingress Controller
If you would like to set up an external ingress to enable external traffic to reach the Limina deployment, you must enable the haproxy-ingress and cert-manager helm charts in the values.yaml file. Additionally, a sample ingress deployment file is included, and can be deployed with self-signed certificates for testing.

If you would like to deploy your own certificate issuer and certificates, please see the [cert-manager docs](https://cert-manager.io/docs/).

The haproxy-ingress configuration required to host a certificate and manage incoming traffic from the ingress to the Limina deployment is included with the chart. For more advanced configuration, please see the [haproxy-ingress docs](https://haproxy-ingress.github.io/docs/getting-started/).

Note: The haproxy-ingress and cert-manager helm charts are not listed as dependencies in this chart, and must be installed separately prior to installation.

```console
# Create a namespaces in your cluster for the cert-manager chart
kubectl create namespace cert-manager

# Upgrade or install cert-manager into the cluster with custom resource definitions
helm upgrade --install \
  cert-manager oci://quay.io/jetstack/charts/cert-manager \
  --namespace cert-manager \
  --set crds.enabled=true \
  --set clusterResourceNamespace=limina

# Required webhook settings if deploying to AWS with the VPC-CNI plugin
#  --set webhook.hostNetwork=true \
#  --set webhook.securePort=10255

# Create a namespaces in your cluster for the haproxy-ingress chart
kubectl create namespace haproxy-controller

# Upgrade or install haproxy-ingress into the cluster
helm upgrade --install \
  haproxy-kubernetes-ingress oci://ghcr.io/haproxytech/helm-charts/kubernetes-ingress \
  --namespace haproxy-controller \
  --set controller.service.type=LoadBalancer

# Required setting for AWS, see https://github.com/haproxytech/helm-charts/tree/main/kubernetes-ingress#installing-on-amazon-elastic-kubernetes-service-eks
#  --set controller.service.enablePorts.quic=false

# Required setting for Azure, see https://github.com/haproxytech/helm-charts/tree/main/kubernetes-ingress#installing-on-azure-managed-kubernetes-service-aks
#  --set controller.service.annotations."service\.beta\.kubernetes\.io/azure-load-balancer-health-probe-request-path"=/healthz
```
Update your custom values.yaml file with the appropriate values under the core ingress
```yaml
core:
  ingress:
    enabled: true
    ingressClassName: "haproxy"
    host: "core.ingress.domain.com"
    tlsSecretName: "limina-core-tls"
```

Proceed with installing limina via helm into the limina namespace
```console
helm upgrade --install \
  limina oci://crprivateaiprod.azurecr.io/helm/limina \
  --namespace limina \
  -f "$(date +%Y%m%d).values.yaml" \
  --version 0.2.0
```

### External Secrets Operator
If you would like to store you license file and docker credentials in an external secret store, you can use the External Secrets Operator helm chart. Please see the [external secrets operator docs](https://external-secrets.io/latest/).

Note: The External Secrets chart is not listed as a dependency in this chart, and must be installed separately prior to installation.

```console
# Create a namespace in your cluster for the limina deployment
kubectl create namespace limina

# Add the External Secrets helm repo
helm repo add external-secrets https://charts.external-secrets.io
helm repo update

# Upgrade or install the External Secrets operator into the limina namespace
helm upgrade --install \
  external-secrets external-secrets/external-secrets \
  --namespace limina

# Create two secrets, one for the license file and one for the docker credentials, in your external secret store of choice
# You can optionally create a secret for environment variables to configure the Limina core container, or for the Limina ingress TLS
```

#### AWS Secrets Manager Steps
##### Example AWS secret for Limina license file
![license-type](./images/aws-license-type.png)
![license-name](./images/aws-license-name.png)
##### Example AWS secret for Limina docker credentials
![docker-type](./images/aws-docker-type.png)
![docker-name](./images/aws-docker-name.png)
##### Example AWS secret for Limina environment variables
![env-type](./images/aws-env-type.png)
![env-name](./images/aws-env-name.png)
##### Example AWS secret for Limina ingress TLS

The TLS certificate for the example must be generated / stored as a binary file. Follow the steps below:

Create a TLS configuration file named ingress.cnf with the appropriate values updated. You can list multiple SAN entries, if neccessary.
```console
[ req ]
default_bits       = 2048
distinguished_name = req_distinguished_name
x509_extensions    = v3_req
prompt             = no

[ req_distinguished_name ]
C                  = CA
ST                 = Ontario
L                  = Toronto
O                  = Limina
OU                 = Engineering
CN                 = api.ingress.domain.com

[ v3_req ]
keyUsage           = critical, digitalSignature, keyEncipherment
extendedKeyUsage   = serverAuth
subjectAltName     = @alt_names

[ alt_names ]
DNS.1              = api.ingress.domain.com
```

Create a private key and certificate (note: certificate issuance / signing from a CA is beyond the scope of this guide)
```console
openssl req -x509 -newkey rsa:2048 -nodes -keyout ingress.key -out ingress.crt -days 365 -config ingress.cnf
openssl pkcs12 -export -out ingress.p12 -inkey ingress.key -in ingress.crt
base64 -i ingress.p12 -o ingress_encoded.txt
```

Create the secret in AWS via the AWS CLI
```console
aws secretsmanager create-secret --name limina-api-tls --secret-binary fileb://ingress.p12
```

##### Configure the AWS Secret Store.
See [the AWS Secrets Manager docs](https://external-secrets.io/latest/provider/aws-secrets-manager/) for detailed instructions.
```console
# Create a secret-store within the limina namespace
# Example AWS secret store based on access key:
kubectl create secret -n limina generic awssm-secret --from-file=./access-key --from-file=./secret-access-key
kubectl apply -f aws-secret-store.yaml
```
```yaml
# aws-secret-store.yaml
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: limina-store
  namespace: limina
spec:
  provider:
    aws:
      service: SecretsManager
      region: ca-central-1
      auth:
        secretRef:
          accessKeyIDSecretRef:
            namespace: limina
            name: awssm-secret
            key: access-key
          secretAccessKeySecretRef:
            namespace: limina
            name: awssm-secret
            key: secret-access-key
```
#### Azure Key Vault Steps
Note: Azure does not allow for multiple key-value pairs per secret entry. To match the data structure of the External Secrets Operator, each secret must be uploaded as a JSON object, with the key matching the property from the values file.

Example Azure secret for Limina license file
![license-name](./images/azure-license-name.png)
```json
{
  "license.json": { "id": 1, "tier": "..." }
}
```
Example Azure secret for Limina docker credentials
![docker-name](./images/azure-docker-name.png)
```json
{
  "server": "crprivateaiprod.azurecr.io",
  "username": "docker-username",
  "password": "docker-password"
}
```
Example Azure secret for Limina environment variables
This is optional, and can be enabled or disabled in the values file.
![env-name](./images/azure-env-name.png)
```json
{
  "PAI_AZ_COMPUTER_VISION_KEY": "secretvalue"
}
```

Next, configure the Azure Secret Store. See the [Azure Key Vault docs](https://external-secrets.io/latest/provider/azure-key-vault/) for more detailed instructions.

You must configure access from the Secret Store object in kubernetes to the Azure Key Vault. In this example, we are using a workload identity federated with an OIDC provider in the kubernetes cluster, and a simple access policy on the key vault. See the [Azure Workload Identity docs](https://azure.github.io/azure-workload-identity/docs/quick-start.html) for more options.

```console
# Set up your AKS cluster and resource group variables
export AKS_CLUSTER_NAME="yourcluster"
export RESOURCE_GROUP="yourresourcegroup"
export USER_ASSIGNED_IDENTITY_NAME="youridentityname"

# Get the Key Vault URL
export KEY_VAULT_URL="$(az keyvault show --name $AKS_CLUSTER_NAME --query 'properties.vaultUri' -o tsv)"

# Create a user-assigned managed identity if using user-assigned managed identity for this tutorial
az identity create --name $USER_ASSIGNED_IDENTITY_NAME --resource-group $RESOURCE_GROUP

# Create key vault policy for UAI
az keyvault set-policy --name $AKS_CLUSTER_NAME \
  --secret-permissions get \
  --object-id $(az identity show --name $USER_ASSIGNED_IDENTITY_NAME --resource-group $RESOURCE_GROUP --query 'principalId' -o tsv)

# Create kubernetes service account bound to UAI
export USER_ASSIGNED_IDENTITY_CLIENT_ID="$(az identity show --name $USER_ASSIGNED_IDENTITY_NAME --resource-group $RESOURCE_GROUP --query 'clientId' -o tsv)"
export USER_ASSIGNED_IDENTITY_TENANT_ID="$(az identity show --name $USER_ASSIGNED_IDENTITY_NAME --resource-group $RESOURCE_GROUP --query 'tenantId' -o tsv)"
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ServiceAccount
metadata:
  annotations:
    azure.workload.identity/client-id: ${USER_ASSIGNED_IDENTITY_CLIENT_ID}
    azure.workload.identity/tenant-id: ${USER_ASSIGNED_IDENTITY_TENANT_ID}
  name: azure-keyvault
  namespace: limina
EOF

# Create federated credential
az identity federated-credential create \
  --name "kubernetes-federated-credential" \
  --identity-name $USER_ASSIGNED_IDENTITY_NAME \
  --resource-group $RESOURCE_GROUP \
  --issuer $(az aks show --resource-group $RESOURCE_GROUP --name $AKS_CLUSTER_NAME --query "oidcIssuerProfile.issuerUrl" -o tsv) \
  --subject "system:serviceaccount:limina:azure-keyvault"

# Create the secret store
cat <<EOF | kubectl apply -f -
apiVersion: external-secrets.io/v1
kind: SecretStore
metadata:
  name: limina-store
  namespace: limina
spec:
  provider:
    azurekv:
      authType: WorkloadIdentity
      vaultUrl: ${KEY_VAULT_URL}
      serviceAccountRef:
        name: azure-keyvault
EOF
```

#### Creating the Secret Store with the chart
Instead of applying the SecretStore and its service account with `kubectl`, you can have the chart create both in the release namespace. Set `externalSecrets.secretStore.create` to true and put the provider configuration under `externalSecrets.secretStore.provider`. It is rendered into the `spec.provider` of a SecretStore named `secretStoreName`, so any provider supported by the External Secrets Operator works. The SecretStore is only created when the External Secrets Operator is enabled for at least one product, and a SecretStore with the same name must not already exist in the namespace.

By default the chart also creates a service account named after the release (`limina-secret-store` for a release named `limina`) that the SecretStore authenticates with. Add the annotations that bind it to your cloud identity under `externalSecrets.secretStore.serviceAccount.annotations`. For the `aws` provider and for the `azurekv` provider with `authType: "WorkloadIdentity"`, the chart references the service account in the provider configuration for you. For other providers, reference it yourself. The cloud identity must trust the service account:

- AWS: the IAM role trust policy must allow `sts:AssumeRoleWithWebIdentity` from your cluster OIDC provider with the subject `system:serviceaccount:limina:limina-secret-store`, and the role needs `secretsmanager:GetSecretValue` on your secrets (plus `kms:Decrypt` for any secret encrypted with a customer managed key, such as the secret AWS RDS manages for the master user)
- Azure: create the federated credential with the subject `system:serviceaccount:limina:limina-secret-store`, instead of creating the `azure-keyvault` service account above

```yaml
externalSecrets:
  secretStoreName: "limina-store"
  secretStore:
    create: true
    # AWS Secrets Manager, authenticating with an IAM role (IRSA)
    serviceAccount:
      annotations:
        eks.amazonaws.com/role-arn: "arn:aws:iam::111122223333:role/limina-secret-store"
    provider:
      aws:
        service: "SecretsManager"
        region: "ca-central-1"
    # Azure Key Vault, authenticating with workload identity
    # serviceAccount:
    #   annotations:
    #     azure.workload.identity/client-id: "00000000-0000-0000-0000-000000000000"
    #     azure.workload.identity/tenant-id: "00000000-0000-0000-0000-000000000000"
    # provider:
    #   azurekv:
    #     authType: "WorkloadIdentity"
    #     vaultUrl: "https://your-key-vault.vault.azure.net/"
```

To use an existing service account in the namespace, set `serviceAccount.create` to false and `serviceAccount.name` to its name. To authenticate with the identity of the External Secrets Operator controller instead, set `serviceAccount.create` to false and leave `serviceAccount.name` empty.

Update your custom values.yaml file to enable the external secrets operator for each product that should read its secrets from the secret store. Enabling it for a product disables the default secret creation for that product. Ensure `secretStoreName` matches the name of the SecretStore you created above (or the one the chart creates), and update the docker credentials and license remoteRefKey and properties as per the secret names and properties, respectively.

```yaml
externalSecrets:
  secretStoreName: "limina-store"
  dockerCredential:
    enabled: true
    remoteRefKey: "limina-docker"
  core:
    enabled: true
    license:
      remoteRefKey: "limina-license"
    env:
      enabled: false # Set to true to load Limina core environment variables from the secret store
    tls:
      enabled: false # Set to true to load the core ingress TLS certificate from the secret store
  async:
    enabled: false # Set to true if you use Async File Support
  platform:
    enabled: false # Set to true if you use the Limina Platform
```

Proceed with installing the helm chart
```console
helm upgrade --install \
  limina oci://crprivateaiprod.azurecr.io/helm/limina \
  --namespace limina \
  -f "$(date +%Y%m%d).values.yaml" \
  --version 0.2.0
```
