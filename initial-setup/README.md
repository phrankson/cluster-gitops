# Initial Setup

## Prerequisites

### AWS account quotas

Each workload cluster you create requires 1 VPC (with an Internet Gateway), 2 Public Subnets,
2 Private Subnets, 2 NAT Gateways, and 2 Elastic IP Addresses. Verify your account quotas
can accommodate the number of clusters you plan to run before starting.

### AWS credentials and permissions

Your local AWS credentials must have sufficient permissions to:

- Create and manage EKS clusters (via `eksctl`)
- Create IAM roles and policies
- Create and manage Secrets Manager secrets
- Create S3 buckets and CloudFormation stacks (if using the automated setup)
- Read/write ECR, VPC, EC2, and related resources (required by Crossplane)

Verify your credentials are configured:
```bash
aws sts get-caller-identity
```

If using AWS SSO:
```bash
aws sso login --profile <your-profile>
export AWS_PROFILE=<your-profile>
```

### Required environment variables

Set these before running any commands. Add them to your shell profile to persist across sessions.

```bash
export ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)
export AWS_REGION=$(aws configure get region)   # or: export AWS_REGION=us-east-1
export EKS_CONSOLE_IAM_ENTITY_ARN=<ARN of the IAM user or role used to access the EKS console>

# Choose a working directory for all generated files (keys, policy docs, kubeconfig, etc.)
export GITOPS_HOME=~/gitops
mkdir -p $GITOPS_HOME

echo "Account: $ACCOUNT_ID  Region: $AWS_REGION"
```

> **Tip:** Paste the four `export` lines into `~/.bash_profile` (or `~/.zshrc` on macOS) so they survive new terminal sessions.

---

## Install required tools

Run the appropriate block for your operating system.

### Detect platform (run once)

```bash
OS=$(uname -s | tr '[:upper:]' '[:lower:]')       # linux or darwin
ARCH=$(uname -m | sed 's/x86_64/amd64/;s/aarch64/arm64/;s/arm64/arm64/')
echo "Platform: $OS/$ARCH"
```

### kubectl

```bash
# Linux (amd64)
sudo curl --silent --location -o /usr/local/bin/kubectl \
   https://s3.us-west-2.amazonaws.com/amazon-eks/1.31.0/2024-09-12/bin/linux/amd64/kubectl
sudo chmod +x /usr/local/bin/kubectl

# macOS (Homebrew)
brew install kubectl
# or pin to the EKS-matched version:
# curl -LO "https://dl.k8s.io/release/v1.31.0/bin/darwin/$(uname -m)/kubectl"
# sudo install -m 755 kubectl /usr/local/bin/kubectl
```

Verify: `kubectl version --client`

### Flux CLI

```bash
curl -s https://fluxcd.io/install.sh | sudo bash
```

Verify: `flux version`

### kubeseal

> **Version coupling:** `kubeseal` CLI **must** match the Sealed Secrets controller chart version.
> This repo pins chart `2.18.5` (controller v0.36.x) → install `kubeseal` v0.36.6.

```bash
# Linux (amd64)
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.36.6/kubeseal-0.36.6-linux-amd64.tar.gz
tar xfz kubeseal-0.36.6-linux-amd64.tar.gz
sudo install -m 755 kubeseal /usr/local/bin/kubeseal

# macOS (arm64)
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.36.6/kubeseal-0.36.6-darwin-arm64.tar.gz
tar xfz kubeseal-0.36.6-darwin-arm64.tar.gz
sudo install -m 755 kubeseal /usr/local/bin/kubeseal

# macOS (amd64)
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.36.6/kubeseal-0.36.6-darwin-amd64.tar.gz
tar xfz kubeseal-0.36.6-darwin-amd64.tar.gz
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

Verify: `kubeseal --version`

### GitHub CLI (gh)

```bash
# macOS
brew install gh

# Linux (Debian/Ubuntu)
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update && sudo apt install gh
```

Authenticate: `gh auth login`

### eksctl

```bash
# Linux (amd64)
curl --silent --location "https://github.com/eksctl-io/eksctl/releases/download/v0.208.0/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin

# macOS
brew tap weaveworks/tap
brew install weaveworks/tap/eksctl
# or direct download:
# curl --silent --location "https://github.com/eksctl-io/eksctl/releases/download/v0.208.0/eksctl_Darwin_arm64.tar.gz" | tar xz -C /tmp
# sudo mv /tmp/eksctl /usr/local/bin
```

Verify: `eksctl version`

### yq

```bash
# Linux (amd64)
sudo curl --silent --location -o /usr/local/bin/yq \
  https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq

# macOS
brew install yq
```

Verify: `yq --version`

### envsubst (macOS only — pre-installed on Linux)

`envsubst` is used to substitute environment variables in config templates. It is bundled with
`gettext` on Linux but must be installed separately on macOS:

```bash
brew install gettext
# gettext installs envsubst as a keg-only binary — link it:
echo 'export PATH="/opt/homebrew/opt/gettext/bin:$PATH"' >> ~/.zshrc
source ~/.zshrc
```

Verify: `envsubst --version`

---

## Clone this repository

```bash
cd $GITOPS_HOME
git clone https://github.com/phrankson/eks-multi-cluster-gitops.git
```

---

## Create a Sealed Secrets keypair in AWS Secrets Manager

Flux uses Sealed Secrets to commit encrypted secrets to Git. The keypair is stored in
Secrets Manager so the Sealed Secrets controller can retrieve it at runtime.

> **Do this before bootstrapping the cluster.** The keypair must be in Secrets Manager
> before External Secrets Operator runs, or the Sealed Secrets controller will start
> without a keypair and generate a random one — breaking any existing SealedSecrets.

```bash
cd $GITOPS_HOME

# Generate a 4096-bit RSA keypair
openssl genrsa -out sealed-secrets-keypair.pem 4096
openssl req -new -x509 \
  -key sealed-secrets-keypair.pem \
  -out sealed-secrets-keypair-public.pem \
  -days 3650

# Build the JSON secret (the newlines must be preserved — use printf, not echo)
CRT=$(cat sealed-secrets-keypair-public.pem)
KEY=$(cat sealed-secrets-keypair.pem)
cat <<EoF > secret.json
{
  "crt": "$CRT",
  "key": "$KEY"
}
EoF

# Store it in AWS Secrets Manager
aws secretsmanager create-secret \
  --name sealed-secrets \
  --secret-string file://secret.json \
  --region ${AWS_REGION}
```

> **Keep `sealed-secrets-keypair.pem` safe.** If it is lost, existing SealedSecrets
> cannot be decrypted and all secrets must be re-sealed with a new keypair.

---

## Create the management cluster

```bash
cd $GITOPS_HOME
cp eks-multi-cluster-gitops/initial-setup/config/mgmt-cluster-eksctl.yaml .
sed -i${SED_INPLACE} "s/AWS_REGION/$AWS_REGION/g" mgmt-cluster-eksctl.yaml
eksctl create cluster -f mgmt-cluster-eksctl.yaml
```

> **macOS `sed` note:** macOS requires `sed -i ''` (with an empty string) while Linux uses
> `sed -i`. To avoid this issue across environments, set a helper variable at the start of
> your session:
> ```bash
> # macOS
> export SED_INPLACE=" ''"
> # Linux
> export SED_INPLACE=""
> ```
> Then all `sed -i${SED_INPLACE}` commands in this guide will work on both platforms.

Cluster creation takes 15–20 minutes. You can proceed to **Create the Git repositories**
in a second terminal while waiting.

---

## Create the Git repositories

You can use GitHub or AWS CodeCommit as the backend for your Git repositories.

[Using GitHub as `GitRepository` backend.](doc/repos/GitHub.md#create-and-prepare-the-git-repositories)

OR

[Using AWS CodeCommit as `GitRepository` backend.](doc/repos/AWSCodeCommit.md#create-and-prepare-the-git-repositories)

After completing either guide, you will have:
- A `gitops-system` repo (cloned locally)
- A `gitops-workloads` repo (cloned locally)
- A `REPO_PREFIX` environment variable set to the URL prefix for your repos

**Important**: `REPO_PREFIX` must match the credential type sealed in `git-secret.yaml`:
- If using **username/PAT** (recommended): `REPO_PREFIX=https://github.com/<user>`
- If using **SSH deploy keys**: `REPO_PREFIX=ssh://git@github.com/<user>`

The sealed git credentials for workload clusters contain `username` and `password` fields,
which only work with HTTPS URLs. Do not use `ssh://` URLs unless you re-seal with SSH keys
(`identity`, `identity.pub`, `known_hosts`).

Verify before continuing:
```bash
echo "REPO_PREFIX: $REPO_PREFIX"
ls $GITOPS_HOME/gitops-system $GITOPS_HOME/gitops-workloads
```

---

## Wait for the management cluster to be active

```bash
aws eks wait cluster-active --name mgmt
echo "Cluster is active"
```

---

## Set up IAM for Crossplane

### Export cluster environment variables

```bash
export MGMT_CLUSTER_INFO=$(aws eks describe-cluster --name mgmt)
export CLUSTER_ARN=$(echo $MGMT_CLUSTER_INFO | yq '.cluster.arn')
export OIDC_PROVIDER_URL=$(echo $MGMT_CLUSTER_INFO | yq '.cluster.identity.oidc.issuer')
export OIDC_PROVIDER=${OIDC_PROVIDER_URL#'https://'}
export CLUSTER_NAME=mgmt
export CLUSTER_NAME_PSUEDO=mgmt

echo "OIDC provider: $OIDC_PROVIDER"
```

### Create the Crossplane IAM role

```bash
cd $GITOPS_HOME

# Render the trust policy with your account/region values
envsubst \
  < eks-multi-cluster-gitops/initial-setup/config/crossplane-role-trust-policy-template.json \
  > crossplane-role-trust-policy.json

# Create the role
CROSSPLANE_IAM_ROLE_ARN=$(aws iam create-role \
  --role-name crossplane-role \
  --assume-role-policy-document file://crossplane-role-trust-policy.json \
  --output text \
  --query "Role.Arn")

echo "Crossplane role ARN: $CROSSPLANE_IAM_ROLE_ARN"

# Render and attach the permission policy
envsubst \
  < eks-multi-cluster-gitops/initial-setup/config/crossplane-role-permission-policy-template.json \
  > crossplane-role-permission-policy.json

CROSSPLANE_IAM_POLICY_ARN=$(aws iam create-policy \
  --policy-name crossplane-policy \
  --policy-document file://crossplane-role-permission-policy.json \
  --output text \
  --query "Policy.Arn")

aws iam attach-role-policy \
  --role-name crossplane-role \
  --policy-arn ${CROSSPLANE_IAM_POLICY_ARN}
```

### Create the `cluster-info` ConfigMap

Flux uses this ConfigMap to substitute `${ACCOUNT_ID}`, `${AWS_REGION}`, etc. in manifests
at reconciliation time.

```bash
kubectl create ns flux-system

kubectl create configmap cluster-info -n flux-system \
  --from-literal=AWS_REGION=${AWS_REGION} \
  --from-literal=ACCOUNT_ID=${ACCOUNT_ID} \
  --from-literal=CLUSTER_ARN=${CLUSTER_ARN} \
  --from-literal=OIDC_PROVIDER=${OIDC_PROVIDER} \
  --from-literal=CLUSTER_NAME=${CLUSTER_NAME} \
  --from-literal=CLUSTER_NAME_PSUEDO=${CLUSTER_NAME}
```

---

## Allow Karpenter node role to access the management cluster

> **Note:** The Karpenter IAM role itself is created later via GitOps (Crossplane).
> This step pre-registers the node role in `aws-auth` so that Karpenter-provisioned
> nodes can join the cluster once the role exists.

```bash
eksctl create iamidentitymapping \
  --cluster mgmt \
  --region=${AWS_REGION} \
  --arn arn:aws:iam::${ACCOUNT_ID}:role/karpenter-node-role \
  --username system:node:{{EC2PrivateDNSName}} \
  --group system:bootstrappers,system:nodes \
  --no-duplicate-arns
```

---

## Allow access to the management cluster from the EKS console

```bash
cd $GITOPS_HOME

# Apply RBAC resources for EKS console access
kubectl apply -f gitops-system/tools-config/eks-console/role.yaml
kubectl apply -f gitops-system/tools-config/eks-console/role-binding.yaml

# Register your IAM entity in aws-auth
eksctl create iamidentitymapping \
  --cluster mgmt \
  --region=${AWS_REGION} \
  --arn ${EKS_CONSOLE_IAM_ENTITY_ARN} \
  --username ${EKS_CONSOLE_IAM_ENTITY_ARN} \
  --no-duplicate-arns
```

> **Verify `EKS_CONSOLE_IAM_ENTITY_ARN` is set:** `echo $EKS_CONSOLE_IAM_ENTITY_ARN`
> If empty, set it to the ARN of the IAM user or role you use to log in to the AWS console.

---

## Populate and update the repositories

Copy this repo's content into your locally cloned `gitops-system` and `gitops-workloads` repos:

```bash
cp -r $GITOPS_HOME/eks-multi-cluster-gitops/repos/gitops-system/* $GITOPS_HOME/gitops-system/
cp -r $GITOPS_HOME/eks-multi-cluster-gitops/repos/gitops-workloads/* $GITOPS_HOME/gitops-workloads/
```

### Update AWS region placeholders

```bash
# Linux
sed -i "s/AWS_REGION/$AWS_REGION/g" \
  $GITOPS_HOME/gitops-system/clusters-config/template/def/eks-cluster.yaml \
  $GITOPS_HOME/gitops-system/tools-config/external-secrets/sealed-secrets-key.yaml

# macOS
sed -i '' "s/AWS_REGION/$AWS_REGION/g" \
  $GITOPS_HOME/gitops-system/clusters-config/template/def/eks-cluster.yaml \
  $GITOPS_HOME/gitops-system/tools-config/external-secrets/sealed-secrets-key.yaml
```

### Update Git repository URLs

Verify `REPO_PREFIX` is set (should have been set during the Git repositories step):
```bash
echo "REPO_PREFIX: $REPO_PREFIX"
```

```bash
# Linux
sed -i "s~REPO_PREFIX~$REPO_PREFIX~g" \
  $GITOPS_HOME/gitops-system/workloads/template/git-repo.yaml \
  $GITOPS_HOME/gitops-system/clusters/mgmt/flux-system/gotk-sync.yaml \
  $GITOPS_HOME/gitops-system/clusters/template/flux-system/gotk-sync.yaml \
  $GITOPS_HOME/gitops-workloads/template/app-template/git-repo.yaml

# macOS
sed -i '' "s~REPO_PREFIX~$REPO_PREFIX~g" \
  $GITOPS_HOME/gitops-system/workloads/template/git-repo.yaml \
  $GITOPS_HOME/gitops-system/clusters/mgmt/flux-system/gotk-sync.yaml \
  $GITOPS_HOME/gitops-system/clusters/template/flux-system/gotk-sync.yaml \
  $GITOPS_HOME/gitops-workloads/template/app-template/git-repo.yaml
```

### Update EKS console IAM entity ARN

```bash
# Linux
sed -i "s~EKS_CONSOLE_IAM_ENTITY_ARN~$EKS_CONSOLE_IAM_ENTITY_ARN~g" \
  $GITOPS_HOME/gitops-system/tools-config/aws-auth/aws-auth-cm.yaml \
  $GITOPS_HOME/gitops-system/tools-config/aws-auth/role-binding.yaml \
  $GITOPS_HOME/gitops-system/clusters/template/aws-auth.yaml

# macOS
sed -i '' "s~EKS_CONSOLE_IAM_ENTITY_ARN~$EKS_CONSOLE_IAM_ENTITY_ARN~g" \
  $GITOPS_HOME/gitops-system/tools-config/aws-auth/aws-auth-cm.yaml \
  $GITOPS_HOME/gitops-system/tools-config/aws-auth/role-binding.yaml \
  $GITOPS_HOME/gitops-system/clusters/template/aws-auth.yaml
```

---

## Create Sealed Secrets for Git repo access

Flux needs credentials to pull from your Git repos. You will create a `Secret` manifest
containing your Git credentials, seal it with `kubeseal`, and commit the `SealedSecret`
to the repo.

### Create the Git credentials Secret manifest

Create a file `$GITOPS_HOME/git-creds-system.yaml` with your Git credentials.
For GitHub using a Personal Access Token:

```bash
cat <<EoF > $GITOPS_HOME/git-creds-system.yaml
apiVersion: v1
kind: Secret
metadata:
  name: flux-system
  namespace: flux-system
type: Opaque
stringData:
  username: <your-github-username>
  password: <your-github-personal-access-token>
EoF
```

> For SSH-based credentials or CodeCommit, refer to the
> [Flux documentation on Git authentication](https://fluxcd.io/flux/components/source/gitrepositories/#secret-reference).

### Seal and place the credentials

```bash
cd $GITOPS_HOME

# Seal for gitops-system repo
kubeseal --cert sealed-secrets-keypair-public.pem --format yaml \
  < git-creds-system.yaml \
  > git-creds-sealed-system.yaml
cp git-creds-sealed-system.yaml gitops-system/clusters-config/template/secrets/git-secret.yaml

# Seal for gitops-workloads repo (same creds, different Secret name)
cp git-creds-system.yaml git-creds-workloads.yaml
yq e '.metadata.name="gitops-workloads"' -i git-creds-workloads.yaml
kubeseal --cert sealed-secrets-keypair-public.pem --format yaml \
  < git-creds-workloads.yaml \
  > git-creds-sealed-workloads.yaml
cp git-creds-sealed-workloads.yaml gitops-system/workloads/template/git-secret.yaml
```

> **Never commit the plaintext `git-creds-system.yaml` or `git-creds-workloads.yaml` files.**
> Only the `SealedSecret` (`git-creds-sealed-*.yaml`) outputs are safe to commit.

---

## Commit and push the repos

```bash
# gitops-system
cd $GITOPS_HOME/gitops-system
git add .
git commit -m "initial commit"
git branch -M main
git push --set-upstream origin main

# gitops-workloads
cd $GITOPS_HOME/gitops-workloads
git add .
git commit -m "initial commit"
git branch -M main
git push --set-upstream origin main
```

---

## Bootstrap the management cluster

Make sure `eksctl` has finished creating the management cluster before running the bootstrap:

```bash
aws eks wait cluster-active --name mgmt && echo "Ready to bootstrap"
```

Then follow the bootstrap guide for your Git backend:

- [Using GitHub as `GitRepository` backend.](doc/repos/GitHub-Bootstrap.md)
- [Using AWS CodeCommit as `GitRepository` backend.](doc/repos/AWSCodeCommit-Bootstrap.md)

---

## Monitor Flux reconciliation

After bootstrap, watch Flux reconcile all the Kustomizations:

```bash
kubectl get kustomization -n flux-system --watch
```

All Kustomizations should reach `Ready=True`. A common failure on first run is the
`external-secrets` Kustomization waiting for the Sealed Secrets controller to come up —
this resolves automatically once all chart deployments complete (typically 5–10 minutes).

Check individual Kustomization errors with:
```bash
kubectl describe kustomization <name> -n flux-system
```

Check HelmRelease status:
```bash
kubectl get helmrelease -A
```
