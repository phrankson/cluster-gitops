# Getting Started: EKS Multi-Cluster GitOps

> **Who this guide is for:** You are comfortable with Kubernetes concepts (pods, deployments, namespaces, RBAC) and have used the AWS CLI before. You have not worked with this specific stack — FluxCD, Crossplane, Sealed Secrets, Karpenter — and want to understand what each piece does and why it is here before you run any commands.
>
> **What you will have at the end:** A running EKS management cluster that manages itself and can provision new workload clusters entirely through Git commits.

---

## What you are building

This system follows a **hub and spoke** model.

```
                        Git repositories
                        ┌─────────────────────────┐
                        │  gitops-system           │  (platform config)
                        │  gitops-workloads         │  (app routing)
                        └────────────┬────────────┘
                                     │ Flux watches
                                     ▼
                   ┌─────────────────────────────────┐
                   │      Management cluster (mgmt)   │
                   │                                  │
                   │  Flux ──► Crossplane ──► AWS API │
                   │                │                 │
                   └────────────────┼─────────────────┘
                          provisions│
                    ┌───────────────┼───────────────┐
                    ▼               ▼               ▼
              Workload A      Workload B      Workload C
              (staging)       (prod)          (dev)
```

You create the management cluster once by hand. After that, every change — new workload cluster, new application, updated configuration — happens by committing to Git. The management cluster reads those commits and makes them real.

### Component map

| Component | What it does | Why it is here |
|---|---|---|
| **FluxCD** | Watches your Git repos and applies any changes it finds to the cluster | The GitOps engine — it is the reason a `git push` becomes a live cluster change |
| **Crossplane** | Calls the AWS API to create real infrastructure (EKS clusters, IAM roles, DynamoDB tables) | Lets you describe AWS resources as Kubernetes manifests so Flux can manage them like any other object |
| **Sealed Secrets** | Decrypts encrypted secrets committed to Git | Git is public (or at least shared) — you cannot commit a raw password. Sealed Secrets lets you commit an encrypted blob that only the controller can open |
| **External Secrets Operator** | Pulls the Sealed Secrets encryption keypair from AWS Secrets Manager and injects it into the cluster | The keypair that Sealed Secrets needs to decrypt must come from somewhere secure — ESO fetches it so no human has to copy it manually |
| **Karpenter** | Provisions EC2 nodes on demand when pods cannot be scheduled | Replaces a fixed node group with one that scales to zero and responds in seconds |
| **AWS Load Balancer Controller** | Creates ALBs and NLBs from Kubernetes `Ingress` and `Service` resources | The in-tree AWS load balancer support is deprecated — this is the current replacement |
| **AWS EBS CSI Driver** | Provides persistent volume support backed by EBS | Required for any workload that needs a `PersistentVolumeClaim` on EKS 1.23+ |
| **Kubecost** | Shows per-namespace and per-workload AWS spend | Makes cluster cost visible without leaving Kubernetes tooling |

### How a workload cluster gets created

1. An operator adds a new directory to `gitops-system/clusters-config/` and commits.
2. Flux detects the change and applies the new manifests to the management cluster.
3. Crossplane reads those manifests and calls the AWS EKS API to provision a new cluster.
4. Flux bootstraps itself onto the new cluster and begins reconciling its own workload config.

You never SSH into anything. You never run `eksctl create cluster` for workload clusters.

---

## Before you start

### AWS account and quotas

Each workload cluster needs: 1 VPC, 2 public subnets, 2 private subnets, 2 NAT Gateways, 2 Elastic IPs. Check your account's Service Quotas before provisioning multiple clusters — the default NAT Gateway limit is often 5 per region.

Your IAM identity needs broad permissions for this initial setup: EKS, IAM, EC2, Secrets Manager, S3. `AdministratorAccess` is the practical minimum for a first run.

Verify your credentials work:

```bash
aws sts get-caller-identity
```

### Environment variables

You will use these variables in almost every command. Set them now and add them to your shell profile (`~/.zshrc` on macOS) so they survive new terminal windows.

```bash
# Your AWS account number — used in IAM ARNs and resource names
export ACCOUNT_ID=$(aws sts get-caller-identity --output text --query Account)

# The region where everything will be created
export AWS_REGION=$(aws configure get region)

# The ARN of the IAM user or role you use to log into the AWS console.
# This is added to the cluster so you can inspect it from the EKS console UI.
export EKS_CONSOLE_IAM_ENTITY_ARN=$(aws sts get-caller-identity --query Arn --output text)

# A local directory for generated files (keypairs, rendered policy docs, etc.)
# that should NOT be committed to Git
export GITOPS_HOME=~/gitops
mkdir -p $GITOPS_HOME

echo "Account : $ACCOUNT_ID"
echo "Region  : $AWS_REGION"
echo "Console : $EKS_CONSOLE_IAM_ENTITY_ARN"
```

> **New terminal?** Re-run the four `export` lines above. Environment variables do not persist between shell sessions unless you add them to your profile.

---

## Install tools

> **macOS users:** All tools below can be installed via Homebrew. Linux alternatives are shown as secondary notes.

### kubectl — the Kubernetes CLI

`kubectl` is how you talk to any Kubernetes cluster. You will use it to inspect Flux resources, check pod status, and apply one-off manifests during setup.

```bash
# macOS
brew install kubectl

# Linux (pinned to EKS 1.31 — must be within one minor version of the cluster)
sudo curl --silent --location -o /usr/local/bin/kubectl \
   https://s3.us-west-2.amazonaws.com/amazon-eks/1.31.0/2024-09-12/bin/linux/amd64/kubectl
sudo chmod +x /usr/local/bin/kubectl
```

Verify: `kubectl version --client`

---

### Flux CLI — the GitOps operator CLI

The `flux` CLI bootstraps Flux onto a cluster and lets you inspect reconciliation status from your terminal.

```bash
# macOS
brew install fluxcd/tap/flux

# Linux
curl -s https://fluxcd.io/install.sh | sudo bash
```

Verify: `flux version`

---

### kubeseal — the secret encryption tool

`kubeseal` takes a plain Kubernetes `Secret` and encrypts it into a `SealedSecret` that is safe to commit to Git. Only the Sealed Secrets controller running in the cluster can decrypt it.

> **Version coupling:** `kubeseal` must match the Sealed Secrets controller version running in the cluster. This repo pins chart `2.18.5` (controller `v0.36.6`). Always install the matching CLI version.

```bash
# macOS
brew install kubeseal

# Linux
wget https://github.com/bitnami-labs/sealed-secrets/releases/download/v0.36.6/kubeseal-0.36.6-linux-amd64.tar.gz
tar xfz kubeseal-0.36.6-linux-amd64.tar.gz
sudo install -m 755 kubeseal /usr/local/bin/kubeseal
```

Verify: `kubeseal --version`

---

### GitHub CLI (`gh`) — the GitHub automation tool

`gh` creates repositories and configures deploy keys without leaving the terminal.

```bash
# macOS
brew install gh

# Linux (Debian/Ubuntu)
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg | sudo dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" | sudo tee /etc/apt/sources.list.d/github-cli.list > /dev/null
sudo apt update && sudo apt install gh
```

Authenticate: `gh auth login`

---

### eksctl — the EKS cluster provisioner

`eksctl` is the official CLI for creating and managing EKS clusters. You will use it once to create the management cluster and occasionally for `aws-auth` mappings.

```bash
# macOS
brew install eksctl

# Linux
curl --silent --location "https://github.com/eksctl-io/eksctl/releases/download/v0.208.0/eksctl_Linux_amd64.tar.gz" | tar xz -C /tmp
sudo mv /tmp/eksctl /usr/local/bin
```

Verify: `eksctl version`

---

### yq — the YAML processor

`yq` is used in scripts to read values out of YAML files (cluster ARN, OIDC URL, etc.) without writing custom parsers.

```bash
# macOS
brew install yq

# Linux
sudo curl --silent --location -o /usr/local/bin/yq \
  https://github.com/mikefarah/yq/releases/download/v4.44.3/yq_linux_amd64
sudo chmod +x /usr/local/bin/yq
```

Verify: `yq --version`

---

### envsubst — the environment variable substitutor

`envsubst` replaces `${VARIABLE}` placeholders in template files with their actual values. Used to render the IAM policy templates in this repo.

```bash
# macOS (pre-installed on Linux)
brew install gettext
brew link --force gettext
```

Verify: `envsubst --version`

---

## Clone this repository

This repository is a **monorepo**. The `repos/` directory contains the content for three separate Git repositories that will be created in the next step. They live together here for convenience during local development but are pushed to separate remotes in production.

```
eks-multi-cluster-gitops/
├── repos/
│   ├── gitops-system/       → pushed to your gitops-system repo
│   ├── gitops-workloads/    → pushed to your gitops-workloads repo
│   └── apps-manifests/      → pushed to per-app repos
├── initial-setup/           → this guide lives here
└── docs/                    → knowledge base and plans
```

```bash
cd $GITOPS_HOME
git clone https://github.com/phrankson/eks-multi-cluster-gitops.git
```

---

## Create the Sealed Secrets encryption keypair

**What Sealed Secrets does:** When you commit a database password to Git, anyone with repo access can read it. Sealed Secrets solves this by encrypting the secret with a public key before it ever touches Git. The encrypted blob (a `SealedSecret`) is useless without the private key, which never leaves the cluster.

**Why the keypair lives in Secrets Manager:** The Sealed Secrets controller needs the private key to decrypt secrets at runtime. Instead of baking it into the cluster at creation time, the External Secrets Operator fetches it from AWS Secrets Manager automatically. This means every cluster — including new workload clusters — gets the same keypair without manual intervention.

**What happens if you lose the private key:** Existing `SealedSecret` resources become permanently unreadable. Back it up.

```bash
cd $GITOPS_HOME

# Step 1: Generate the keypair with openssl (kubeseal is not involved here)
openssl genrsa -out sealed-secrets-keypair.pem 4096
openssl req -new -x509 \
  -key sealed-secrets-keypair.pem \
  -out sealed-secrets-keypair-public.pem \
  -days 3650
# Accept defaults or fill in the certificate fields — the values do not matter functionally

# Step 2: Bundle into JSON
CRT=$(cat sealed-secrets-keypair-public.pem)
KEY=$(cat sealed-secrets-keypair.pem)
cat <<EoF > secret.json
{
  "crt": "$CRT",
  "key": "$KEY"
}
EoF

# Step 3: Upload to Secrets Manager
aws secretsmanager create-secret \
  --name sealed-secrets \
  --secret-string file://secret.json \
  --region ${AWS_REGION}
```

> **Keep `sealed-secrets-keypair.pem` backed up outside this directory.** Do not commit it to Git.

---

## Create the management cluster

**Management cluster vs workload clusters:** The management cluster is the control plane of this system. It runs Flux, Crossplane, and all the tooling. It does not run your applications. Workload clusters run applications — and they are provisioned and managed *by* the management cluster via Crossplane.

**Why eksctl and not Terraform/CDK:** `eksctl` is the official EKS provisioning CLI maintained by AWS. For a single one-time cluster creation it is the lowest-friction option. Workload clusters are provisioned differently — by Crossplane, declaratively, via Git.

**What the config file sets up:**
- `version: "1.31"` — Kubernetes version (must be current to use modern Karpenter v1 APIs)
- `iam.withOIDC: true` — creates an OIDC identity provider, required for Pod Identity and IRSA
- `vpc.nat.gateway: Single` — one NAT Gateway to reduce cost for the management cluster
- `privateNetworking: true` — nodes live in private subnets; only the API server is public
- `instanceType: m5.large` — three of these provide enough capacity for the management tooling

```bash
cd $GITOPS_HOME
cp eks-multi-cluster-gitops/initial-setup/config/mgmt-cluster-eksctl.yaml .

# Replace the AWS_REGION placeholder in the config
# macOS:
sed -i '' "s/AWS_REGION/$AWS_REGION/g" mgmt-cluster-eksctl.yaml
# Linux:
# sed -i "s/AWS_REGION/$AWS_REGION/g" mgmt-cluster-eksctl.yaml

eksctl create cluster -f mgmt-cluster-eksctl.yaml
```

This takes 15–25 minutes. Open a second terminal and continue with the next section while waiting.

---

## Create the Git repositories

**Why two separate repos?** `gitops-system` and `gitops-workloads` have different owners and different change cadences.

| Repo | Who touches it | What it contains |
|---|---|---|
| `gitops-system` | Platform team | Cluster tooling, Crossplane compositions, Flux bootstrap config |
| `gitops-workloads` | Governance / app teams | Per-cluster pointers to app repos, access control |

Keeping them separate means an app team committing a new deployment cannot accidentally affect cluster-level tooling, and vice versa.

Follow the instructions for your chosen Git backend, then return here:

- [GitHub](doc/repos/GitHub.md#create-and-prepare-the-git-repositories)
- [AWS CodeCommit](doc/repos/AWSCodeCommit.md#create-and-prepare-the-git-repositories)

When done, confirm `REPO_PREFIX` is set — you will need it shortly:

```bash
echo "REPO_PREFIX: $REPO_PREFIX"
```

---

## Wait for the management cluster

Before continuing, confirm the cluster is fully active:

```bash
aws eks wait cluster-active --name mgmt
echo "Cluster is ready"

# Point kubectl at the new cluster
aws eks update-kubeconfig --name mgmt --region $AWS_REGION
kubectl get nodes   # should show 3 nodes in Ready state
```

---

## Set up IAM for Crossplane

**What Crossplane needs IAM for:** Crossplane runs inside the cluster but calls the AWS API to provision real resources — EKS clusters, IAM roles, VPCs. To do that it needs an IAM role with the right permissions. The role is created here manually once; after that Crossplane manages IAM roles for all other tools via GitOps.

### Export cluster variables

```bash
export MGMT_CLUSTER_INFO=$(aws eks describe-cluster --name mgmt)
export CLUSTER_ARN=$(echo $MGMT_CLUSTER_INFO | yq '.cluster.arn')
export CLUSTER_NAME=mgmt
export CLUSTER_NAME_PSUEDO=mgmt
```

### Create the Crossplane IAM role

```bash
cd $GITOPS_HOME

# Render the trust policy — this controls which Kubernetes service account can assume the role
envsubst \
  < eks-multi-cluster-gitops/initial-setup/config/crossplane-role-trust-policy-template.json \
  > crossplane-role-trust-policy.json

CROSSPLANE_IAM_ROLE_ARN=$(aws iam create-role \
  --role-name crossplane-role \
  --assume-role-policy-document file://crossplane-role-trust-policy.json \
  --output text \
  --query "Role.Arn")
echo "Crossplane role: $CROSSPLANE_IAM_ROLE_ARN"

# Render and attach the permission policy — this is what Crossplane can actually do
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

**What this ConfigMap is:** Flux has a feature called `postBuild.substituteFrom` — it reads values from a ConfigMap and substitutes them into manifests at reconciliation time. Every manifest that contains `${AWS_REGION}`, `${ACCOUNT_ID}`, or `${CLUSTER_NAME}` gets those values injected by Flux at runtime, not by you manually.

This is why you do not need to `sed`-replace those placeholders in most of the manifests — Flux does it automatically from this ConfigMap.

```bash
kubectl create ns flux-system

kubectl create configmap cluster-info -n flux-system \
  --from-literal=AWS_REGION=${AWS_REGION} \
  --from-literal=ACCOUNT_ID=${ACCOUNT_ID} \
  --from-literal=CLUSTER_ARN=${CLUSTER_ARN} \
  --from-literal=CLUSTER_NAME=${CLUSTER_NAME} \
  --from-literal=CLUSTER_NAME_PSUEDO=${CLUSTER_NAME}
```

---

## Allow Karpenter nodes to join the cluster

**Why this step happens before Karpenter exists:** Karpenter-provisioned EC2 nodes authenticate to the Kubernetes API using an IAM role called `karpenter-node-role`. That role needs to be registered in the cluster's `aws-auth` ConfigMap before any node can join. The role itself does not exist in IAM yet — Crossplane will create it later via GitOps. Registering the name now is safe and prevents a race condition on first node launch.

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

**What this does:** The EKS console lets you browse cluster resources in the AWS web UI. By default it cannot see anything inside the cluster because Kubernetes RBAC is separate from IAM. This step creates a ClusterRole that grants read access and maps your IAM identity to it so the console can display pods, deployments, and nodes.

```bash
cd $GITOPS_HOME
kubectl apply -f gitops-system/tools-config/eks-console/role.yaml
kubectl apply -f gitops-system/tools-config/eks-console/role-binding.yaml

eksctl create iamidentitymapping \
  --cluster mgmt \
  --region=${AWS_REGION} \
  --arn ${EKS_CONSOLE_IAM_ENTITY_ARN} \
  --username ${EKS_CONSOLE_IAM_ENTITY_ARN} \
  --no-duplicate-arns
```

---

## Populate and update the repositories

Copy the manifests from the monorepo into your two separate repos:

```bash
cp -r $GITOPS_HOME/eks-multi-cluster-gitops/repos/gitops-system/* $GITOPS_HOME/gitops-system/
cp -r $GITOPS_HOME/eks-multi-cluster-gitops/repos/gitops-workloads/* $GITOPS_HOME/gitops-workloads/
```

### Update the AWS region placeholder

**Why only one file needs `sed` here:** Most manifests use `${AWS_REGION}` as a Flux substitution variable — Flux replaces it at runtime from the `cluster-info` ConfigMap you created earlier. The `eks-cluster.yaml` template is an exception because it is used by Crossplane to provision clusters, and it needs the literal value baked in.

```bash
# macOS
sed -i '' "s/AWS_REGION/$AWS_REGION/g" \
  $GITOPS_HOME/gitops-system/clusters-config/template/def/eks-cluster.yaml

# Linux
# sed -i "s/AWS_REGION/$AWS_REGION/g" \
#   $GITOPS_HOME/gitops-system/clusters-config/template/def/eks-cluster.yaml
```

### Update Git repository URLs

**What `REPO_PREFIX` is:** The manifests contain placeholder `REPO_PREFIX` where the actual Git URL prefix should go. For GitHub it looks like `https://github.com/your-org`. The `sed` commands below stamp your actual URL into every `GitRepository` manifest so Flux knows where to pull from.

Verify it is set first:
```bash
echo "REPO_PREFIX: $REPO_PREFIX"
```

```bash
# macOS
sed -i '' "s~REPO_PREFIX~$REPO_PREFIX~g" \
  $GITOPS_HOME/gitops-system/workloads/template/git-repo.yaml \
  $GITOPS_HOME/gitops-system/clusters/mgmt/flux-system/gotk-sync.yaml \
  $GITOPS_HOME/gitops-system/clusters/template/flux-system/gotk-sync.yaml \
  $GITOPS_HOME/gitops-workloads/template/app-template/git-repo.yaml

# Linux: replace sed -i '' with sed -i
```

### Update the EKS console IAM entity ARN

```bash
# macOS
sed -i '' "s~EKS_CONSOLE_IAM_ENTITY_ARN~$EKS_CONSOLE_IAM_ENTITY_ARN~g" \
  $GITOPS_HOME/gitops-system/tools-config/aws-auth/aws-auth-cm.yaml \
  $GITOPS_HOME/gitops-system/tools-config/aws-auth/role-binding.yaml \
  $GITOPS_HOME/gitops-system/clusters/template/aws-auth.yaml

# Linux: replace sed -i '' with sed -i
```

---

## Create Git credentials as Sealed Secrets

**The problem:** Flux needs to pull from your private Git repos. That means it needs credentials — a GitHub Personal Access Token or an SSH key. You cannot commit those credentials in plaintext.

**The solution — step by step:**

1. You write the credentials into a standard Kubernetes `Secret` manifest on your local machine.
2. `kubeseal` encrypts it using the public key from the keypair you generated earlier, producing a `SealedSecret`.
3. You commit the `SealedSecret` (the encrypted blob) to Git — it is useless without the private key.
4. The Sealed Secrets controller in the cluster holds the private key (fetched from Secrets Manager by ESO) and decrypts the `SealedSecret` back into a real `Secret` at runtime.
5. Flux reads that `Secret` and uses it to authenticate to Git.

### Step 1: Create the plaintext credential file

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

> For SSH keys or CodeCommit, see the [Flux authentication docs](https://fluxcd.io/flux/components/source/gitrepositories/#secret-reference).

### Step 2: Seal and place the secrets

```bash
cd $GITOPS_HOME

# Seal for gitops-system (Secret name must be "flux-system")
kubeseal --cert sealed-secrets-keypair-public.pem --format yaml \
  < git-creds-system.yaml \
  > git-creds-sealed-system.yaml
cp git-creds-sealed-system.yaml gitops-system/clusters-config/template/secrets/git-secret.yaml

# Seal for gitops-workloads (same credentials, different Secret name)
cp git-creds-system.yaml git-creds-workloads.yaml
yq e '.metadata.name="gitops-workloads"' -i git-creds-workloads.yaml
kubeseal --cert sealed-secrets-keypair-public.pem --format yaml \
  < git-creds-workloads.yaml \
  > git-creds-sealed-workloads.yaml
cp git-creds-sealed-workloads.yaml gitops-system/workloads/template/git-secret.yaml
```

> **Never commit `git-creds-system.yaml` or `git-creds-workloads.yaml`.** Add them to `.gitignore`. Only the `git-creds-sealed-*.yaml` files are safe to commit.

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

**What bootstrapping does:** Up to this point, the cluster is a plain EKS cluster with nothing running on it. Bootstrapping installs Flux into the cluster and tells it which Git repository to watch. From this moment on, the cluster is self-managing — any commit to `gitops-system` will be automatically reconciled without you running any more `kubectl apply` commands.

Make sure the cluster is active before proceeding:

```bash
aws eks wait cluster-active --name mgmt && echo "Ready"
```

Follow the bootstrap guide for your Git backend:

- [GitHub](doc/repos/GitHub-Bootstrap.md)
- [AWS CodeCommit](doc/repos/AWSCodeCommit-Bootstrap.md)

---

## Monitor Flux reconciliation

**What reconciliation means:** Flux continuously compares what is in Git (desired state) with what is running in the cluster (actual state). When they differ, it applies the difference. On first boot, everything differs — nothing is running yet — so Flux applies the entire `gitops-system` tree, which triggers Crossplane to start, which starts provisioning IAM roles, which allows Karpenter to start, and so on. This cascade takes time.

Watch the status of all Flux `Kustomization` resources:

```bash
watch -n 30 kubectl get kustomization -n flux-system
```

**Expected final state — all `READY=True`:**

```
NAME                             READY   STATUS
clusters-config                  True    Applied revision: main@sha1:...
crossplane                       True    Applied revision: main@sha1:...
crossplane-aws-provider          True    Applied revision: main@sha1:...
crossplane-core                  True    Applied revision: main@sha1:...
crossplane-eks-composition       True    Applied revision: main@sha1:...
crossplane-k8s-provider          True    Applied revision: main@sha1:...
external-secrets                 True    Applied revision: main@sha1:...
flux-system                      True    Applied revision: main@sha1:...
karpenter                        True    Applied revision: main@sha1:...
karpenter-config                 True    Applied revision: main@sha1:...
sealed-secrets                   True    Applied revision: main@sha1:...
```

**Timeline:** 20–40 minutes on first run. Most of this is Crossplane provisioning IAM roles in AWS — it cannot be rushed.

### If `karpenter-config` stays `False` after 10 minutes

This kustomization contains both the Karpenter `NodePool` and the Crossplane `Role` for `karpenter-node-role`. If Crossplane has not finished creating the role yet, Karpenter's `EC2NodeClass` cannot validate and the kustomization fails. Apply the role manually to break the cycle:

```bash
kubectl apply -f $GITOPS_HOME/eks-multi-cluster-gitops/repos/gitops-system/tools-config/karpenter-config/role.yaml
```

Then wait for Crossplane to sync it:

```bash
until kubectl get role.iam.aws.crossplane.io karpenter-node-role \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null | grep -q True; do
  echo "Waiting for karpenter-node-role..."; sleep 10
done
echo "Ready — karpenter-config will reconcile on the next Flux interval"
```

---

## Final health check

Run each command and compare against the expected output. Do not proceed to provisioning workload clusters until everything is green.

```bash
# 1. All Flux kustomizations reconciled
kubectl get kustomization -n flux-system
# Expected: READY=True for all rows

# 2. Crossplane AWS provider healthy
kubectl get provider provider-aws
# Expected: INSTALLED=True  HEALTHY=True

# 3. Karpenter running
kubectl get pods -n kube-system -l app.kubernetes.io/name=karpenter
# Expected: 2/2 Running

# 4. EC2NodeClass ready (Karpenter can provision nodes)
kubectl get ec2nodeclass default \
  -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}{"\n"}'
# Expected: True

# 5. Crossplane IAM roles provisioned
kubectl get role.iam.aws.crossplane.io
# Expected: READY=True  SYNCED=True for all roles

# 6. Sealed Secrets controller running
kubectl get pods -n sealed-secrets
# Expected: 1/1 Running

# 7. External Secrets Operator running
kubectl get pods -n external-secrets
# Expected: Running
```

If everything is green, your management cluster is fully operational. You can now provision workload clusters by adding entries to `gitops-system/clusters-config/` and committing.

---

> **Need to rebuild this cluster later?** Most of this guide does not need to be repeated — the Git repos, Secrets Manager keypair, and IAM roles all survive a cluster deletion. See `doc/re-bootstrap.md` for the shorter rebuild path.
