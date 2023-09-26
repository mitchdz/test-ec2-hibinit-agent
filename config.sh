aws_instance_name_prefix="$USER-hibinit-test"
aws_region="${AWS_REGION:-}"
aws_instance_type="t3.micro"
aws_keyname="${AWS_KEYNAME:-}"
# NOTE: Ensure security group has ssh access
aws_security_group="${AWS_SECURITYGROUP:-}"

lunar_ami="ami-0fc5ace025b0c51d3"
jammy_ami="ami-0fe8bec493a81c7da"
focal_ami="ami-0c5863072fc83557e"

