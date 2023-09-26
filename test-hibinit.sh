#!/bin/bash

set -x

# Get variables from config.sh
source config.sh

while [[ $# -gt 0 ]]; do
  option="$1"
  case $option in
    --release)
      release="$2"
      shift
      shift
      ;;
    *)
      # Do nothing
      ;;
  esac
done

case $release in 
    jammy)
    aws_ami="$jammy_ami"
    aws_instance_name="${aws_instance_name_prefix}-$release"
    ;;
    lunar)
    aws_ami="$lunar_ami"
    aws_instance_name="${aws_instance_name_prefix}-$release"
    ;;
    focal)
    aws_ami="$focal_ami"
    aws_instance_name="${aws_instance_name_prefix}-$release"
    ;;
    *)
    echo "ERROR: supply a proper release with --release <version>"
    exit 1
    ;;
esac

wait_for_ssh() {
    # $1 is ipaddr
    local max_ssh_attempts=10
    local ssh_attempt_sleep_time=10
    local ipaddr=$1

    # Loop until SSH is successful or max_attempts is reached
    for ((i = 1; i <= $max_ssh_attempts; i++)); do
        ssh \
            -o StrictHostKeyChecking=no \
            -o UserKnownHostsFile=/dev/null \
            -o GlobalKnownHostsFile=/dev/null \
            -i ~/.ssh/${aws_keyname}.pem ubuntu@${ipaddr} exit
        if [ $? -eq 0 ]; then
            echo "SSH connection successful."
            break
        else
            echo "Attempt $i: SSH connection failed. Retrying in $ssh_attempt_sleep_time seconds..."
            sleep $ssh_attempt_sleep_time
        fi
    done

    if [ $i -gt $max_ssh_attempts ]; then
        echo "Max SSH connection attempts reached. Exiting."
    fi
}

instance_id=$(aws ec2 run-instances \
    --region ${aws_region} \
    --image-id ${aws_ami} \
    --count 1 \
    --instance-type ${aws_instance_type} \
    --key-name ${aws_keyname} \
    --security-group-ids ${aws_security_group} \
    --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=${aws_instance_name}}]" \
    --metadata-options "HttpTokens=required" \
    --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"Encrypted":true,"DeleteOnTermination":true,"VolumeSize":24,"VolumeType":"gp2"}}]' \
    --hibernation-options 'Configured=true' \
    --query 'Instances[0].InstanceId' \
    --output text
)

aws ec2 wait instance-running --region $aws_region --instance-ids $instance_id
ipaddr=$(aws ec2 describe-instances --instance-ids $instance_id --region $aws_region \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

wait_for_ssh $ipaddr

# Enable proposed
ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -i ~/.ssh/${aws_keyname}.pem ubuntu@${ipaddr} \
    'echo "deb http://archive.ubuntu.com/ubuntu $(lsb_release -cs)-proposed restricted main multiverse universe" | sudo tee /etc/apt/sources.list.d/ubuntu-$(lsb_release -cs)-proposed.list' 

# Update ec2-hibinit-agent to proposed package
ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -i ~/.ssh/${aws_keyname}.pem ubuntu@${ipaddr} \
    'sudo apt-get update -y && sudo apt-get install -y ec2-hibinit-agent -t $(lsb_release -cs)-proposed'

# Check version
ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -i ~/.ssh/${aws_keyname}.pem ubuntu@${ipaddr} \
    dpkg -l ec2-hibinit-agent | grep ec2-hibinit-agent | awk '{print $3}'

# Create a test process file
test_file_name="allocate_mem.py"
/bin/cat <<EOM >./$test_file_name
#!/usr/bin/python3
import time

# Allocate 200MB chunk of memory
size = 200 * 1024 * 1024 # 200MB
memory_chunk = bytearray(size)

print("Allocated 200MB of memory.")

# Enter indefinite loop
while True:
    time.sleep(1) # Wait for 1 second

# The script will never reach this point
EOM

chmod +x ./$test_file_name

# Copy test process to remote system
scp \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -i ~/.ssh/${aws_keyname}.pem ./$test_file_name ubuntu@${ipaddr}:~/

# Start the process in the background
ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -i ~/.ssh/${aws_keyname}.pem -f ubuntu@${ipaddr} \
    "sh -c 'nohup python3 ~/allocate_mem.py < /dev/null &'"

# Check the process is running
ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -i ~/.ssh/${aws_keyname}.pem ubuntu@${ipaddr} \
    ps aux | grep allocate_mem | grep -v grep

# Hibernate the instance
wait_for_hibernate_available() {
    local instance_id=$1
    local max_hibernate_attempts=10
    local hibernate_attempt_sleep_time=10

    # Loop until Hibernation is successful or max_attempts is reached
    for ((i = 1; i <= $max_hibernate_attempts; i++)); do
        aws ec2 stop-instances --region $aws_region --instance-ids $instance_id --hibernate
        if [ $? -eq 0 ]; then
            echo "Hibernation request successful."
            break
        else
            echo "Attempt $i: Hibernation attempt failed. Retrying in $hibernate_attempt_sleep_time seconds..."
            sleep $hibernate_attempt_sleep_time
        fi
    done

    if [ $i -gt $max_hibernate_attempts ]; then
        echo "Max Hibernation attempts reached. Exiting."
    fi
}
wait_for_hibernate_available $instance_id
aws ec2 wait instance-stopped --region $aws_region --instance-ids $instance_id
aws ec2 start-instances --region $aws_region --instance-ids $instance_id
aws ec2 wait instance-running --region $aws_region --instance-ids $instance_id

ipaddr=$(aws ec2 describe-instances --instance-ids $instance_id --region $aws_region \
    --query 'Reservations[0].Instances[0].PublicIpAddress' \
    --output text)

wait_for_ssh $ipaddr


# Check the process is running
out=$(ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -i ~/.ssh/${aws_keyname}.pem ubuntu@${ipaddr} \
    ps aux | grep allocate_mem | grep -v grep)

echo $out

echo "RESULTS:"

if [ -z "$out" ]; then
    echo "No process running after starting. Test failed."
    echo "ec2-hibinit-agent $version failed on AMI $aws_ami"
    exit 1
fi

version=$(ssh \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o GlobalKnownHostsFile=/dev/null \
    -i ~/.ssh/${aws_keyname}.pem ubuntu@${ipaddr} \
    dpkg -l ec2-hibinit-agent | grep ec2-hibinit-agent | awk '{print $3}')

echo "ec2-hibinit-agent $version passed on AMI $aws_ami"