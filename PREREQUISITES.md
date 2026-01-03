# Prerequisites

This document outlines the requirements and setup process for working with the mapping conflict resolution tools and procedures in this repository.

## Required Infrastructure

### Running Elasticsearch and Kibana Deployment

To use the scripts and procedures in this repository, you **must** have a functioning Elasticsearch and Kibana deployment. This repository does **not** include deployment automation - it focuses solely on resolving mapping conflicts in an existing Elasticsearch environment.

**Minimum Requirements:**
- **Elasticsearch**: Version 8.x or 9.x
- **Kibana**: Matching version to Elasticsearch
- **Access Level**: Stack Management permissions
- **Storage**: Hot tier with capacity for temporary index copies (2x largest affected index)

### Why You Need This

The reindexing procedures require:
1. **Dev Tools** access in Kibana for running Elasticsearch queries
2. **Stack Management** access for component template management
3. **Index Management** permissions for ILM policy application
4. **Sufficient storage** in the Hot tier for temporary backing index copies

---

## Quick Setup Using helm-elastic-fleet-quickstart

If you don't already have an Elasticsearch and Kibana deployment, the fastest way to get started is using the `helm-elastic-fleet-quickstart` repository.

### Step 1: Clone the helm-elastic-fleet-quickstart Repository

**Before cloning this repository**, set up your Elasticsearch environment:

```bash
# Navigate to your development directory
cd ~

# Clone the Elastic Fleet quickstart repository
git clone https://github.com/bmayroseEGS/helm-elastic-fleet-quickstart.git
cd helm-elastic-fleet-quickstart
```

### Step 2: Run the Machine Setup Script

This script installs Docker, Kubernetes (K3s), Helm, and sets up a local Docker registry.

```bash
cd deployment_infrastructure
./setup-machine.sh
```

**What This Script Does:**
- Installs Docker Engine
- Installs K3s (lightweight Kubernetes)
- Installs kubectl command-line tool
- Installs Helm package manager
- Starts a local Docker registry on `localhost:5000`
- Configures Docker group permissions

**During Execution:**
When the script asks about cloning a repository, you can choose to clone this `solving_mapping_conflicts_w_reindexing` repository at that time:

```
Do you want to clone an additional repository? (y/n): y
Enter repository URL: https://github.com/YOUR_USERNAME/solving_mapping_conflicts_w_reindexing.git
```

If you skip this step, you can clone this repository manually later.

**At the End:**
When prompted to activate Docker permissions, choose **Yes** to complete the setup:

```
Do you want to activate Docker permissions now and setup the registry? (y/n): y
```

The script will:
- Activate Docker group membership with `newgrp docker`
- Start the local Docker registry
- Display "Setup Complete!" with next steps

### Step 3: Deploy Elasticsearch and Kibana

After the setup script completes, deploy **only Elasticsearch and Kibana** (not Logstash or Fleet Server):

```bash
# From the helm-elastic-fleet-quickstart directory
cd ../helm_charts
./deploy.sh
```

**Important - Component Selection:**

When the deploy script prompts you, select:
- **Elasticsearch**: `y` (Yes)
- **Kibana**: `y` (Yes)
- **Logstash**: `n` (No - not needed for mapping conflicts)

```
Deploy Elasticsearch? (y/n): y
Deploy Kibana? (y/n): y
Deploy Logstash? (y/n): n
```

**Why Only Elasticsearch and Kibana?**

For resolving mapping conflicts, you only need:
- **Elasticsearch** - The core database with the data and mappings
- **Kibana** - UI for Dev Tools and Stack Management

Fleet Server and Logstash are not required for this workflow.

**Deployment Time:**
- Elasticsearch: ~2-5 minutes
- Kibana: ~1-3 minutes

Wait for both components to reach "Running" status before proceeding.

### Step 4: Access Kibana

Once deployed, access Kibana from your local machine using port forwarding.

**If deploying on a remote server:**

From your **local machine**, create an SSH tunnel with port forwarding:

```bash
ssh -i your-key.pem -L 9200:localhost:9200 -L 5601:localhost:5601 user@server
```

Then, on the **remote server**, run:

```bash
kubectl port-forward -n elastic svc/elasticsearch-master 9200:9200 &
kubectl port-forward -n elastic svc/kibana 5601:5601 &
```

**If deploying locally:**

```bash
kubectl port-forward -n elastic svc/elasticsearch-master 9200:9200 &
kubectl port-forward -n elastic svc/kibana 5601:5601 &
```

**Access Kibana:**

Open your browser and navigate to:
```
http://localhost:5601
```

**Login credentials:**
- **Username**: `elastic`
- **Password**: `elastic`

### Step 5: Verify Deployment

Before proceeding with mapping conflict resolution, verify your deployment:

**Check Elasticsearch:**
```bash
curl http://localhost:9200
```

Expected response:
```json
{
  "name" : "elasticsearch-master-0",
  "cluster_name" : "elasticsearch",
  "version" : {
    "number" : "9.2.2",
    ...
  }
}
```

**Check Kibana:**

Navigate to: `http://localhost:5601/app/dev_tools#/console`

Run this query in Dev Tools:
```elasticsearch
GET _cluster/health
```

Expected response:
```json
{
  "cluster_name" : "elasticsearch",
  "status" : "green",
  "number_of_nodes" : 1,
  ...
}
```

---

## Alternative Deployment Methods

If you already have Elasticsearch and Kibana running through other means (ECK, ECE, Elastic Cloud, etc.), you can use this repository directly. Ensure you have:

### Required Access Permissions

1. **Kibana Access:**
   - Stack Management
   - Index Management
   - Data Views
   - Dev Tools

2. **Elasticsearch Access:**
   - `manage` cluster privilege (for `_reindex`)
   - `manage_ilm` privilege (for ILM policy management)
   - `write` and `read` access to affected indices/data streams

### Network Access

- HTTP/HTTPS access to Elasticsearch (default: port 9200)
- HTTP/HTTPS access to Kibana (default: port 5601)

---

## Verifying Prerequisites

Before starting mapping conflict resolution, verify:

### 1. Elasticsearch is Running
```bash
curl http://localhost:9200/_cluster/health?pretty
```

### 2. Kibana is Accessible
Navigate to: `http://localhost:5601`

### 3. Dev Tools Works
In Kibana, go to: `Management` → `Dev Tools`

Run:
```elasticsearch
GET /
```

### 4. Stack Management Access
In Kibana: `Management` → `Stack Management` → `Index Management`

You should see your data streams and indices.

### 5. Sufficient Storage
Check cluster disk usage:
```elasticsearch
GET _cat/allocation?v
```

Ensure you have at least **2x** the size of your largest affected index available in the Hot tier.

---

## Component Template Access

You'll need to access and modify component templates:

**In Kibana:**
1. Navigate to: `Stack Management` → `Index Management` → `Component Templates`
2. You should be able to view and edit templates
3. Create test template to verify permissions

---

## Data Stream Permissions

Verify you can manage data streams:

```elasticsearch
# List data streams
GET _data_stream

# Check specific data stream
GET _data_stream/logs-*
```

---

## ILM Policy Access

Verify ILM policy management:

```elasticsearch
# List ILM policies
GET _ilm/policy

# Check specific policy
GET _ilm/policy/logs
```

---

## Troubleshooting Prerequisites

### Cannot Access Kibana

**Check pod status:**
```bash
kubectl get pods -n elastic
```

**Check Kibana logs:**
```bash
kubectl logs -n elastic -l app=kibana
```

**Verify port-forward:**
```bash
kubectl port-forward -n elastic svc/kibana 5601:5601
```

### Cannot Connect to Elasticsearch

**Check Elasticsearch pods:**
```bash
kubectl get pods -n elastic -l app=elasticsearch
```

**Test connectivity:**
```bash
curl http://localhost:9200/_cluster/health
```

### Permission Denied Errors

**Verify user roles in Kibana:**
1. Go to: `Stack Management` → `Security` → `Users`
2. Check `elastic` user has `superuser` role

**Or create a dedicated user with required permissions:**
```elasticsearch
POST _security/user/reindex_user
{
  "password" : "your-password-here",
  "roles" : [ "superuser" ]
}
```

### Insufficient Storage

**Check current disk usage:**
```elasticsearch
GET _cat/allocation?v&h=node,disk.used,disk.avail,disk.total,disk.percent
```

**If storage is low:**
1. Delete old or unused indices
2. Adjust ILM policies to move data to warm/cold tier sooner
3. Add more storage to your Kubernetes cluster

---

## Next Steps

Once you have verified all prerequisites:

1. **Identify mapping conflicts**: Navigate to Kibana → `Stack Management` → `Data Views`
2. **Follow the main README**: Return to [README.md](README.md) for reindexing procedures
3. **Review examples**: Check the `examples/` directory for common scenarios

---

## Quick Reference Commands

**Port Forwarding (Remote Server):**
```bash
# From local machine
ssh -i your-key.pem -L 9200:localhost:9200 -L 5601:localhost:5601 user@server

# On remote server
kubectl port-forward -n elastic svc/elasticsearch-master 9200:9200 &
kubectl port-forward -n elastic svc/kibana 5601:5601 &
```

**Port Forwarding (Local):**
```bash
kubectl port-forward -n elastic svc/elasticsearch-master 9200:9200 &
kubectl port-forward -n elastic svc/kibana 5601:5601 &
```

**Access URLs:**
- Elasticsearch: `http://localhost:9200`
- Kibana: `http://localhost:5601`
- Dev Tools: `http://localhost:5601/app/dev_tools#/console`

**Default Credentials:**
- Username: `elastic`
- Password: `elastic`

---

## Support

For setup issues with the helm-elastic-fleet-quickstart repository:
- Visit: https://github.com/bmayroseEGS/helm-elastic-fleet-quickstart
- Check: `TROUBLESHOOTING.md` in that repository

For Elasticsearch/Kibana specific issues:
- Elasticsearch Documentation: https://www.elastic.co/guide/en/elasticsearch/reference/current/index.html
- Kibana Documentation: https://www.elastic.co/guide/en/kibana/current/index.html
