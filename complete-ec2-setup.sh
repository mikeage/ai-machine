#!/bin/bash

# Exit on error
set -e

echo "Starting EC2 setup process..."

RUN_ID="$(date +%Y%m%d-%H%M%S)"

# Create key pair and save it
KEY_NAME="ec2-key-ai-$RUN_ID"
aws ec2 create-key-pair \
	--key-name "$KEY_NAME" \
	--query 'KeyMaterial' \
	--output text >"${KEY_NAME}.pem"

# Set correct permissions for key file
chmod 400 "${KEY_NAME}.pem"
echo "Created key pair: $KEY_NAME"

# Create security group
SG_NAME="ssh-restricted-ai-$RUN_ID"
SG_ID=$(aws ec2 create-security-group \
	--group-name "$SG_NAME" \
	--description "Security group for SSH access from specific IPs" \
	--output text \
	--query 'GroupId')

echo "Created security group: $SG_NAME ($SG_ID)"

# Add SSH rules for specific IPs
aws ec2 authorize-security-group-ingress \
	--group-id "$SG_ID" \
	--protocol tcp \
	--port 22 \
	--cidr 192.118.35.101/32

aws ec2 authorize-security-group-ingress \
	--group-id "$SG_ID" \
	--protocol tcp \
	--port 22 \
	--cidr 192.118.33.100/32

echo "Added security group rules for SSH access"

# Get latest Ubuntu AMI ID
AMI_ID=$(aws ec2 describe-images \
	--owners 099720109477 \
	--filters "Name=name,Values=ubuntu/images/hvm-ssd/ubuntu-jammy-22.04-amd64-server-*" \
	"Name=state,Values=available" \
	--query "sort_by(Images, &CreationDate)[-1].ImageId" \
	--output text)

AMI_ID=$(aws ec2 describe-images --owners 136693071363 --query "sort_by(Images, &CreationDate)[-1].ImageId" --filters "Name=name,Values=debian-12-amd64-*" --output text)
echo "Using AMI: $AMI_ID"

# Get default VPC ID
VPC_ID=$(aws ec2 describe-vpcs \
	--filters "Name=isDefault,Values=true" \
	--query 'Vpcs[0].VpcId' \
	--output text)

echo "Using VPC: $VPC_ID"

# Get the first availability zone
ZONE=$(aws ec2 describe-availability-zones \
	--query 'AvailabilityZones[0].ZoneName' \
	--output text)

# Check if subnet already exists
SUBNET_EXISTS=$(aws ec2 describe-subnets \
	--filters "Name=cidrBlock,Values=172.31.1.0/24" \
	--query 'Subnets[].[SubnetId]' \
	--output text)

if [[ -n "$SUBNET_EXISTS" ]]; then
	echo "Subnet already exists: $SUBNET_EXISTS"
	SUBNET_ID="$SUBNET_EXISTS"
else
	# Create the subnet if it doesn't exist
	SUBNET_ID=$(aws ec2 create-subnet \
		--vpc-id "$VPC_ID" \
		--cidr-block "172.31.1.0/24" \
		--availability-zone "$ZONE" \
		--query 'Subnet.SubnetId' \
		--output text)
	echo "Created subnet: $SUBNET_ID in zone $ZONE"
	# Enable auto-assign public IP for the subnet
	aws ec2 modify-subnet-attribute \
		--subnet-id "$SUBNET_ID" \
		--map-public-ip-on-launch
	echo "Created subnet: $SUBNET_ID in zone $ZONE"
fi

# Create EC2 instance
echo "Creating EC2 instance..."
INSTANCE_DATA=$(aws ec2 run-instances \
	--image-id "$AMI_ID" \
	--instance-type g4dn.xlarge \
	--subnet-id "$SUBNET_ID" \
	--security-group-ids "$SG_ID" \
	--associate-public-ip-address \
	--key-name "$KEY_NAME" \
	--count 1 \
	--block-device-mappings "DeviceName=/dev/xvda,Ebs={VolumeSize=50,VolumeType=gp3}" \
	--tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value='ec2-ai-$RUN_ID'}]' \
	--output json)

INSTANCE_ID=$(echo "$INSTANCE_DATA" | jq -r '.Instances[0].InstanceId')

echo "Waiting for instance to be running..."
aws ec2 wait instance-running --instance-ids "$INSTANCE_ID"

# Get instance public IP
PUBLIC_IP=$(aws ec2 describe-instances \
	--instance-ids "$INSTANCE_ID" \
	--query 'Reservations[0].Instances[0].PublicIpAddress' \
	--output text)

# Create the auto-shutdown script
cat <<'EOFSCRIPT' >configuration.sh
#!/bin/bash

# Create the monitoring script
cat << 'EOF' > /tmp/monitor-activity.sh
#!/bin/bash

# Function to count active SSH sessions
count_active_sessions() {
    who | wc -l
}

# Function to check if there was any SSH activity in the last 15 minutes
check_recent_activity() {
    last -s -15min | grep -v "reboot" | grep -v "wtmp" | grep -v '^$' | wc -l
}

# Main loop
sleep 600  # Wait for 10 minutes before starting monitoring
while true; do
    active_sessions=$(count_active_sessions)
    recent_activity=$(check_recent_activity)
    
    if [ $active_sessions -eq 0 ] && [ $recent_activity -eq 0 ]; then
        logger "No active sessions or recent activity detected. Shutting down."
        /sbin/shutdown -h now
    fi
    
    sleep 60
done
EOF

# Create the systemd service file
cat << 'EOF' > /tmp/activity-monitor.service
[Unit]
Description=Monitor SSH activity and auto-shutdown
After=network.target

[Service]
Type=simple
ExecStart=/usr/local/bin/monitor-activity.sh
Restart=always

[Install]
WantedBy=multi-user.target
EOF

# Move files to their proper locations
sudo mv /tmp/monitor-activity.sh /usr/local/bin/
sudo mv /tmp/activity-monitor.service /etc/systemd/system/

# Make the script executable
sudo chmod +x /usr/local/bin/monitor-activity.sh

# Enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable activity-monitor
sudo systemctl start activity-monitor

echo "Auto-shutdown monitoring has been installed and started."
echo "The system will shut down after 15 minutes of inactivity."

cat <<EOF > /tmp/instance-storage.service
[Unit]
Description=Format and mount ephemeral storage
After=local-fs.target

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/usr/sbin/mkfs.ext4 /dev/nvme1n1
ExecStart=/usr/bin/mkdir -p /mnt/ephemeral
ExecStart=/usr/bin/mount /dev/nvme1n1 /mnt/ephemeral
ExecStart=/usr/bin/chmod 777 /mnt/ephemeral
ExecStop=/usr/bin/umount /mnt/ephemeral

[Install]
WantedBy=multi-user.target
EOF
sudo mv /tmp/instance-storage.service /etc/systemd/system/

# Enable and start the service
sudo systemctl daemon-reload
sudo systemctl enable instance-storage
sudo systemctl start instance-storage

wget https://raw.githubusercontent.com/alacritty/alacritty/master/extra/alacritty.info && tic -xe alacritty,alacritty-direct alacritty.info && sudo tic -xe alacritty,alacritty-direct alacritty.info && rm alacritty.info
curl -fsSL https://astral.sh/uv/install.sh | sh
wget https://github.com/neovim/neovim/releases/download/v0.10.3/nvim-linux64.tar.gz && tar xfz nvim-linux64.tar.gz && sudo mv nvim-linux64/bin/* /usr/local/bin/ && sudo mv nvim-linux64/lib/* /usr/local/lib/ && sudo mv nvim-linux64/share/* /usr/local/share/ && rm -rf nvim-linux64 nvim-linux64.tar.gz
EOFSCRIPT

# Wait for instance to be ready for SSH
echo "Waiting for instance to be ready for SSH..."
while ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -i "${KEY_NAME}.pem" admin@${PUBLIC_IP} echo "SSH connection successful" >/dev/null 2>&1; do
	sleep 5
done

# Copy and execute the auto-shutdown script
echo "Installing auto-shutdown script, ephemeral formatting, and a few tools (nvim, uv, alacritty terminfo)..."
scp -i "${KEY_NAME}.pem" configuration.sh admin@${PUBLIC_IP}:~/
ssh -i "${KEY_NAME}.pem" admin@${PUBLIC_IP} "sudo bash configuration.sh"

# Clean up local auto-shutdown script
rm configuration.sh

# Output final information
echo ""
echo "=== Setup Complete ==="
echo "Instance ID: $INSTANCE_ID"
echo "Public IP: $PUBLIC_IP"
echo "Key pair file: ${KEY_NAME}.pem"
echo "Security Group: $SG_NAME"
echo ""
echo "To connect to your instance:"
echo "ssh -i ${KEY_NAME}.pem admin@${PUBLIC_IP}"
echo "To shutdown the instance manually:"
echo "aws ec2 stop-instances --instance-ids $INSTANCE_ID"
echo "To start the instance:"
echo "aws ec2 start-instances --instance-ids $INSTANCE_ID"
echo "To get the current IP:"
echo "aws ec2 describe-instances --instance-ids $INSTANCE_ID --query 'Reservations[0].Instances[0].PublicIpAddress' --output text"
echo "To delete everything:"
echo "./cleanup-script.sh $INSTANCE_ID $SG_NAME $KEY_NAME"
echo ""
echo "Commands to run for AI:"
echo "curl -fsSL https://ollama.com/install.sh | sh  # Run models locally"
echo "sudo sed -i '/\[Service\]/a Environment=\"OLLAMA_MODELS=/mnt/ephemeral\"' /etc/systemd/system/ollama.service && sudo systemctl daemon-reload && sudo systemctl restart ollama.service"
echo "uv tool install llm  # LLM CLI tool"
echo "llm install llm-ollama  # Plugin to interact with ollama"
echo "ollama pull llama3.2"
echo "llm -m llama3.2 'Hello, world'"

