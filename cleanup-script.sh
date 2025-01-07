#!/bin/bash

# Exit on error
set -e

if [ $# -ne 3 ]; then
    echo "Usage: $0 <instance-id> <security-group-name> <key-pair-name>"
    echo "Example: $0 i-1234567890abcdef0 ssh-restricted-20240106-123456 ec2-key-20240106-123456"
    exit 1
fi

INSTANCE_ID=$1
SG_NAME=$2
KEY_NAME=$3

echo "Starting cleanup process..."

# Terminate EC2 instance
echo "Terminating instance $INSTANCE_ID..."
aws ec2 terminate-instances --instance-ids "$INSTANCE_ID"

# Wait for instance termination
echo "Waiting for instance to terminate..."
aws ec2 wait instance-terminated --instance-ids "$INSTANCE_ID"

# Delete security group (with retry logic since instance termination might take time to propagate)
echo "Deleting security group $SG_NAME..."
max_attempts=6
attempt=1
while [ $attempt -le $max_attempts ]; do
    if aws ec2 delete-security-group --group-name "$SG_NAME" 2>/dev/null; then
        echo "Security group deleted successfully"
        break
    else
        echo "Attempt $attempt: Failed to delete security group. Waiting 10 seconds..."
        sleep 10
        attempt=$((attempt + 1))
    fi
done

if [ $attempt -gt $max_attempts ]; then
    echo "Warning: Failed to delete security group after $max_attempts attempts"
fi

# Delete key pair
echo "Deleting key pair $KEY_NAME..."
aws ec2 delete-key-pair --key-name "$KEY_NAME"

# Remove local key file
if [ -f "${KEY_NAME}.pem" ]; then
    echo "Removing local key file ${KEY_NAME}.pem..."
    rm "${KEY_NAME}.pem"
fi

echo "Cleanup complete!"
