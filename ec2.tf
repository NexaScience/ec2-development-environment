# --- Ubuntu 24.04 LTS AMI ---
data "aws_ami" "ubuntu" {
  most_recent = true
  owners      = ["099720109477"] # Canonical

  filter {
    name   = "name"
    values = ["ubuntu/images/hvm-ssd-gp3/ubuntu-noble-24.04-amd64-server-*"]
  }

  filter {
    name   = "virtualization-type"
    values = ["hvm"]
  }

  filter {
    name   = "architecture"
    values = ["x86_64"]
  }
}

# --- Key Pair ---
resource "aws_key_pair" "deploy" {
  key_name   = "${var.PROJECT_NAME}-key"
  public_key = var.SSH_PUBLIC_KEY
}

# --- Security Group ---
resource "aws_security_group" "claude_dev" {
  name        = "${var.PROJECT_NAME}-sg"
  description = "Security group for Claude Code dev instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SSH from allowed CIDR"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = [var.ALLOWED_SSH_CIDR]
  }

  egress {
    description = "Allow all outbound"
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = {
    Name = "${var.PROJECT_NAME}-sg"
  }
}

# --- IAM Role for SSM ---
resource "aws_iam_role" "ssm" {
  name = "${var.PROJECT_NAME}-ssm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ssm.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ssm" {
  name = "${var.PROJECT_NAME}-ssm-profile"
  role = aws_iam_role.ssm.name
}

# --- EC2 Instance ---
resource "aws_instance" "claude_dev" {
  ami                    = data.aws_ami.ubuntu.id
  instance_type          = var.INSTANCE_TYPE
  key_name               = aws_key_pair.deploy.key_name
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.claude_dev.id]
  iam_instance_profile   = aws_iam_instance_profile.ssm.name

  root_block_device {
    volume_size = var.ROOT_VOLUME_SIZE
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required" # IMDSv2
    http_put_response_hop_limit = 1
  }

  user_data = templatefile("${path.module}/scripts/setup.sh", {
    SLACK_WEBHOOK_URL = var.SLACK_WEBHOOK_URL
    GIT_REPO_URL      = var.GIT_REPO_URL
    INFRA_REPO_URL    = var.INFRA_REPO_URL
  })

  tags = {
    Name = "${var.PROJECT_NAME}-instance"
  }
}
