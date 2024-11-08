
# MSR Data Migration Script

The MSR Data Migration script facilitates the migration of accounts, repositories, organizations, tags, and related data between two Mirantis Secure Registries (MSRs).


### Image Transfer with Skopeo

This script uses **Skopeo**, a command-line utility for managing container images, to transfer images directly between the source and destination registries.
Skopeo is particularly useful as it eliminates the need for a local docker daemon and pulling image to local node.

#### How Skopeo Works in the Script:
1. **Authentication**:
   - Skopeo utilizes credentials provided in the environment variables, or directly as command flags:
     - `SOURCE_MSR_USERNAME`, `SOURCE_MSR_TOKEN` for the source registry.
     - `DEST_MSR_USERNAME`, `DEST_MSR_TOKEN` for the destination registry.

2. **Transfer Process**:
   - Images are transferred directly from the source MSR (`SOURCE_MSR_URL`) to the destination MSR (`DEST_MSR_URL`) without requiring local storage.
   - Image paths are formatted as `docker://source_image` to `docker://destination_image`.

3. **TLS Verification**:
   - TLS verification is disabled for both source and destination (`--src-tls-verify=false` and `--dest-tls-verify=false`) to ensure compatibility across diverse environments during migration.

4. **Parallel Execution**:
   - Transfers are executed in parallel using **GNU Parallel** to execute tasks like repository and image migrations concurrently. This approach allows to reduce the migration time significantly.

Example:
```bash
echo "$LIST" | parallel -j $PARALLEL_PROCESS_COUNT --tag 'echo "Processing {}"; <your_command_here>'
```

#### Example Skopeo Command:
```bash
skopeo copy \
    --src-creds "$SOURCE_MSR_USERNAME:$SOURCE_MSR_TOKEN" \
    --dest-creds "$DEST_MSR_USERNAME:$DEST_MSR_TOKEN" \
    --src-tls-verify=false --dest-tls-verify=false \
    docker://$SOURCE_MSR_URL/$IMAGE_NAME \
    docker://$DEST_MSR_URL/$IMAGE_NAME
```


## (Script) Requirements

- Ensure passwordless SSH access to source MSR nodes.
- Access to the destination MSR's Kubernetes environment with `kubectl`.
- Username/password/token to access source and destination MSRs.
- In the destination MSR environment, `rethinkdb-cli pod` should be running.

## (Script) Execution flow

1. **Environment Setup**:
   
   - Validates environment variables and required files.
   - Checks for the existence of necessary tools (e.g., SSH, `kubectl`, `rethinkdb-cli`).

3. **Migration files**:

   - Creates JSON files for accounts, repositories, tags, etc., using SSH commands and database queries to the source MSR environment.

4. **Migration**:
   - **Accounts**: Migrates user accounts and tokens.
   - **Organizations**: Transfers organizations, teams, and memberships.
   - **Repositories**: Migrates repository metadata.
   - **Tags**: Handles the migration of tags and associated images.

5. **Logging**:

   - Logs each step in the migration process to a log file.

## (Script) Flags and Options
| Option              | Description                                       |
|---------------------|---------------------------------------------------|
| `-F, --files`       | Generate required migration files.                |
| `-a, --accounts`    | Migrate user accounts and their tokens.           |
| `-o, --orgs`        | Migrate organizations, teams, and memberships.    |
| `-r, --repos`       | Migrate repositories.                             |
| `-t, --tags`        | Migrate repository tags and associated images.    |
| `-L, --list-tags`   | List all tags from `tags.json`.                   |
| `-A, --migrate-all` | Perform all migrations sequentially.              |
| `-h, --help`        | Display help message.                             |

## Environment Setup
The script requires an environment file with the following variables.

#### Example of an environment file: `.msr_data_migration.env`

```bash
# Source cluster variables
MKE_NODE=1.2.3.4
MKE_NODE_SSH_KEY=/config/id_rsa  #if executed as a container, then this is the path inside the container.
MKE_NODE_SSH_USER=ubuntu

SOURCE_MSR_NODE=1.2.3.5
SOURCE_MSR_SSH_KEY=/config/id_rsa  #if executed as a container, then this is the path inside the container.
SOURCE_MSR_SSH_USER=ubuntu

SOURCE_MSR_USERNAME=migration_user
SOURCE_MSR_TOKEN=source-token
SOURCE_MSR_URL=source.msr.example.com

# Destination cluster variables
KUBECONFIG=/config/kubeconfig #Kubeconfig for destination MSR. If script is executed as a container, then this is the path inside the container.
DEST_MSR_URL=destination.msr.example.com:34034
DEST_MSR_USERNAME=migration_user
DEST_MSR_TOKEN=destination-token

DEST_MSR_K8S_NAMESPACE=default

PARALLEL_PROCESS_COUNT=5
TOKEN_LIMIT=50
```

### Running the Script

Use the following command to execute the script as a container:

_Replace tag with `_amd64` or `_arm64` in tag suffix as needed._

```bash
docker run --rm -it \
    --entrypoint /bin/bash \
    -e KUBECONFIG=/config/kubeconfig \
    -e ENV_FILE=.msr_data_migration.env \
    -v /path/to/destination/msr/kubeconfig:/config/kubeconfig:ro \
    -v /path/to/id_rsa:/config/id_rsa:ro \
    -v $(pwd):/app \
    --workdir /app \
    sharmapr/msr_data_migration:06112024_amd64
```
```
4aabba1696d3:/app#
4aabba1696d3:/app# msr_data_migration -h
Using the environment variables file .msr_data_migration.env

Usage: /msr-migration/bin/msr_data_migration [OPTIONS]

Options:
  -F, --files          Create required migration files (must be run first).
  -a, --accounts       Migrate user accounts and their tokens.
  -o, --orgs           Migrate organizations, teams, and memberships.
  -r, --repos          Migrate repositories.
  -t, --tags           Migrate repository tags and associated images.
  -L, --list-tags      List all tags from 'tags.json'.
  -A, --migrate-all    Perform all migrations sequentially (requires '-F' first).
  -h, --help           Display this help message.

Requirements:
- Passwordless SSH access to source MKE and DTR nodes.
- Destination K8s environment kubeconfig.
- Username/password/token to access source and destination MSRs.
- A running rethinkdb-cli pod on the destination MSR.

Note: Run with '-F' to generate migration files before using other options.
4aabba1696d3:/app#
```


## (Script) Running the commands

1. **Prepare the Environment File**:
   
   - Ensure that all required variables are correctly set in the `.msr_data_migration.env` _[default name]_ file.
   - Alternatively a different environment file can be created and passed as variable `ENV_FILE`.

3. **Run the Script**:

   Start by creating migration files using the `-F` flag:
     ```bash
     4aabba1696d3:/app# msr_data_migration -F
     ```
     
   Proceed with specific migrations or execute all steps sequentially:
     ```bash
     4aabba1696d3:/app# msr_data_migration -a
     4aabba1696d3:/app# msr_data_migration -o
     4aabba1696d3:/app# msr_data_migration -r
     4aabba1696d3:/app# msr_data_migration -t

     # OR
     
     4aabba1696d3:/app# msr_data_migration --migrate-all
     ```

5. **Monitor Logs**:
   
   - Logs are stored in the `msr-migration-logs` directory.



  
