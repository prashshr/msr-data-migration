# Use a minimal base image
FROM alpine:latest

# Install dependencies
RUN apk add --no-cache \
    vim \
    bash \
    curl \
    openssh \
    jq \
    parallel \
    docker-cli \
    skopeo

# Install kubectl by downloading the binary directly
RUN curl -LO "https://dl.k8s.io/release/$(curl -sL https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl" && \
    chmod +x kubectl && \
    mv kubectl /usr/local/bin/

# Create the directory for the script and add it to the container
RUN mkdir -p /msr-migration
COPY msr_data_migration_in_container.sh /msr-migration/bin/msr_data_migration

# Make the script executable
RUN chmod +x /msr-migration/bin/msr_data_migration

ENV PATH="/msr-migration/bin:${PATH}"

# Define the entrypoint for the container
ENTRYPOINT ["/msr-migration/msr_data_migration.sh"]
