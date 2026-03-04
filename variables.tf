variable "AWS_REGION" {
  description = "AWS region to deploy resources"
  type        = string
  default     = "ap-northeast-1"
}

variable "PROJECT_NAME" {
  description = "Project name used for resource naming and tagging"
  type        = string
  default     = "claude-dev"
}

variable "INSTANCE_TYPE" {
  description = "EC2 instance type"
  type        = string
  default     = "t3.xlarge"
}

variable "ALLOWED_SSH_CIDR" {
  description = "CIDR block allowed to SSH into the instance"
  type        = string
}

variable "SSH_PUBLIC_KEY" {
  description = "SSH public key for EC2 access"
  type        = string
}

variable "SLACK_WEBHOOK_URL" {
  description = "Slack Incoming Webhook URL for notifications"
  type        = string
  sensitive   = true
}

variable "GIT_REPO_URL" {
  description = "Git repository URL to clone on EC2 (must contain .devcontainer/)"
  type        = string
}

variable "INFRA_REPO_URL" {
  description = "URL of this infrastructure repository to clone on EC2"
  type        = string
}

variable "ROOT_VOLUME_SIZE" {
  description = "Root EBS volume size in GB"
  type        = number
  default     = 100
}
